-- =====================================================================
--  Reels Analiz Takibi – Veritabanı Şeması (PostgreSQL 15+ / Supabase uyumlu)
--
--  Kapsam (sitedeki 3 sekme + yardımcı veriler):
--    1) İçerikler        -> contents, content_metrics, content_rates, content_sources
--    2) Paylaşım takvimi -> publish_plans, plan_media
--    3) Fikirler         -> ideas, tags, idea_tags
--    4) Yardımcı         -> users, accounts, user_settings, import_batches
--
--  Mevcut localStorage anahtarları:
--    reels-analiz-v1 -> contents (+ metrics/rates/sources)
--    reels-plan-v1   -> publish_plans (+ plan_media)
--    reels-fikir-v1  -> ideas (+ tags)
-- =====================================================================

BEGIN;

-- ---------- Sabit değer listeleri (enum) ------------------------------
CREATE TYPE plan_status   AS ENUM ('planlandi', 'hazir', 'paylasildi');   -- Planlandı / Hazır / Paylaşıldı
CREATE TYPE post_type     AS ENUM ('reels', 'gonderi', 'carousel');       -- Reels / Gönderi / Carousel
CREATE TYPE idea_status   AS ENUM ('fikir', 'cekilecek', 'cekildi');      -- Fikir / Çekilecek / Çekildi
CREATE TYPE rate_kind     AS ENUM ('skip', 'share', 'like', 'save', 'repost', 'comment');
                                                                          -- Geçme / Paylaşım / Beğenme / Kaydetme / Yeniden paylaşım / Yorum
CREATE TYPE rate_compare  AS ENUM ('lower', 'average', 'higher');         -- Daha düşük / Ortalama / Daha yüksek
CREATE TYPE traffic_source AS ENUM ('reels_tab', 'feed', 'explore', 'profile', 'search', 'other');
                                                                          -- Reels sekmesi / Akış / Keşfet / Profil / Arama / Diğer
CREATE TYPE import_kind   AS ENUM ('contents', 'plans', 'ideas');

-- ---------- Ortak yardımcı: updated_at otomatik güncelleme -----------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =====================================================================
--  4) YARDIMCI TABLOLAR
-- =====================================================================

-- Kullanıcı (şimdilik tek kişilik site olsa da çok kullanıcıya hazır)
CREATE TABLE users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email         text NOT NULL UNIQUE,
  display_name  text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- Instagram hesabı: tüm içerik/plan/fikirler bir hesaba bağlanır
CREATE TABLE accounts (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  handle      text NOT NULL,                       -- örn. kullanici_adi
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, handle)
);

-- Kullanıcı ayarları (tema vb.)
CREATE TABLE user_settings (
  user_id     uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  theme       text NOT NULL DEFAULT 'auto' CHECK (theme IN ('auto', 'light', 'dark')),
  locale      text NOT NULL DEFAULT 'tr-TR',
  updated_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_user_settings_upd BEFORE UPDATE ON user_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Excel / JSON içe aktarma geçmişi (denetim ve geri alma için)
CREATE TABLE import_batches (
  id            bigserial PRIMARY KEY,
  account_id    uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind          import_kind NOT NULL,
  file_name     text,
  rows_added    integer NOT NULL DEFAULT 0,
  rows_skipped  integer NOT NULL DEFAULT 0,        -- boş veya tekrar olduğu için atlananlar
  created_at    timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
--  1) İÇERİKLER (Reels analiz takibi)
-- =====================================================================

CREATE TABLE contents (
  id             bigserial PRIMARY KEY,
  account_id     uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  title          text NOT NULL DEFAULT '',          -- İçerik adı
  published_on   date,                              -- Yayın tarihi
  duration_s     integer CHECK (duration_s >= 0),   -- Video süresi (sn)
  vs_last        text,                              -- "Son içeriklere göre" (örn. En son 5/10)
  note           text,                              -- Notlar
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_contents_account_date ON contents (account_id, published_on DESC);
CREATE TRIGGER trg_contents_upd BEFORE UPDATE ON contents
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Sitedeki 500 içerik sınırı (hesap başına)
CREATE OR REPLACE FUNCTION enforce_content_limit() RETURNS trigger AS $$
BEGIN
  IF (SELECT count(*) FROM contents WHERE account_id = NEW.account_id) >= 500 THEN
    RAISE EXCEPTION 'Bir hesap için en fazla 500 içerik girilebilir.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_contents_limit BEFORE INSERT ON contents
  FOR EACH ROW EXECUTE FUNCTION enforce_content_limit();

-- Özet + etkileşim + kitle (içerik başına tek satır)
CREATE TABLE content_metrics (
  content_id       bigint PRIMARY KEY REFERENCES contents(id) ON DELETE CASCADE,
  -- Özet
  views            integer CHECK (views >= 0),       -- Görüntülemeler
  viewers          integer CHECK (viewers >= 0),     -- Görüntüleyenler
  avg_watch_s      numeric(8,2) CHECK (avg_watch_s >= 0), -- Ort. izlenme süresi (sn)
  follows          integer CHECK (follows >= 0),     -- Takipler
  -- Etkileşim
  likes            integer CHECK (likes >= 0),
  comments         integer CHECK (comments >= 0),
  reposts          integer CHECK (reposts >= 0),     -- Yeniden paylaşım
  shares           integer CHECK (shares >= 0),      -- Paylaşım
  saves            integer CHECK (saves >= 0),       -- Kaydetme
  -- İzleme süresi & kitle (%)
  retention_end_pct   numeric(5,2) CHECK (retention_end_pct   BETWEEN 0 AND 100), -- Videonun sonunda izleyen
  followers_pct       numeric(5,2) CHECK (followers_pct       BETWEEN 0 AND 100), -- Takipçiler
  non_followers_pct   numeric(5,2) CHECK (non_followers_pct   BETWEEN 0 AND 100), -- Takipçi olmayanlar
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_content_metrics_upd BEFORE UPDATE ON content_metrics
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- "Görüntülemeyi etkileyen oranlar" (6 oran; değer + karşılaştırma etiketi)
CREATE TABLE content_rates (
  content_id  bigint NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
  kind        rate_kind NOT NULL,
  value_pct   numeric(6,2) CHECK (value_pct BETWEEN 0 AND 100),
  compared    rate_compare,                          -- Daha düşük / Ortalama / Daha yüksek
  PRIMARY KEY (content_id, kind)
);

-- Görüntüleme kaynakları (%)
CREATE TABLE content_sources (
  content_id  bigint NOT NULL REFERENCES contents(id) ON DELETE CASCADE,
  source      traffic_source NOT NULL,
  pct         numeric(5,2) CHECK (pct BETWEEN 0 AND 100),
  PRIMARY KEY (content_id, source)
);

-- =====================================================================
--  3) FİKİRLER
-- =====================================================================

CREATE TABLE ideas (
  id          bigserial PRIMARY KEY,
  account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  title       text NOT NULL CHECK (length(btrim(title)) > 0),
  note        text,                                  -- Not / senaryo
  status      idea_status NOT NULL DEFAULT 'fikir',
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, title)                         -- Excel içe aktarmadaki "aynı başlık = tekrar" kuralı
);
CREATE INDEX idx_ideas_account_status ON ideas (account_id, status);
CREATE TRIGGER trg_ideas_upd BEFORE UPDATE ON ideas
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Etiketler (virgülle yazılan metin yerine ayrı tablo)
CREATE TABLE tags (
  id          bigserial PRIMARY KEY,
  account_id  uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name        text NOT NULL CHECK (length(btrim(name)) > 0),
  UNIQUE (account_id, name)
);

CREATE TABLE idea_tags (
  idea_id  bigint NOT NULL REFERENCES ideas(id) ON DELETE CASCADE,
  tag_id   bigint NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
  PRIMARY KEY (idea_id, tag_id)
);
CREATE INDEX idx_idea_tags_tag ON idea_tags (tag_id);

-- =====================================================================
--  2) PAYLAŞIM TAKVİMİ
-- =====================================================================

CREATE TABLE publish_plans (
  id              bigserial PRIMARY KEY,
  account_id      uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  planned_date    date NOT NULL,                     -- Tarih
  planned_time    time,                              -- Saat (boş olabilir)
  type            post_type   NOT NULL DEFAULT 'reels',
  status          plan_status NOT NULL DEFAULT 'planlandi',
  title           text NOT NULL CHECK (length(btrim(title)) > 0),
  note            text,
  idea_id         bigint REFERENCES ideas(id)    ON DELETE SET NULL,  -- "Takvime ekle" ile gelen fikir
  content_id      bigint REFERENCES contents(id) ON DELETE SET NULL,  -- paylaşıldıktan sonra analiz kaydı
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  -- Excel içe aktarmadaki tekrar kuralı: tarih + saat + başlık
  UNIQUE NULLS NOT DISTINCT (account_id, planned_date, planned_time, title)
);
CREATE INDEX idx_plans_account_date ON publish_plans (account_id, planned_date, planned_time);
CREATE INDEX idx_plans_upcoming ON publish_plans (account_id, planned_date)
  WHERE status <> 'paylasildi';                      -- "Yaklaşan paylaşımlar" listesi
CREATE TRIGGER trg_plans_upd BEFORE UPDATE ON publish_plans
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Plan görselleri: dosyalar nesne depolamada (Supabase Storage / S3), veritabanında yalnızca yol
CREATE TABLE plan_media (
  id            bigserial PRIMARY KEY,
  plan_id       bigint NOT NULL REFERENCES publish_plans(id) ON DELETE CASCADE,
  position      smallint NOT NULL CHECK (position BETWEEN 1 AND 10),   -- carousel sırası
  storage_path  text NOT NULL,                       -- örn. plans/42/1.jpg
  mime_type     text NOT NULL DEFAULT 'image/jpeg',
  width         integer,
  height        integer,
  bytes         integer CHECK (bytes >= 0),
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plan_id, position)
);

-- Reels ve Gönderi için en fazla 1 görsel, Carousel için en fazla 10
CREATE OR REPLACE FUNCTION enforce_media_limit() RETURNS trigger AS $$
DECLARE
  t post_type;
  c integer;
BEGIN
  SELECT type INTO t FROM publish_plans WHERE id = NEW.plan_id;
  SELECT count(*) INTO c FROM plan_media WHERE plan_id = NEW.plan_id;
  IF t <> 'carousel' AND c >= 1 THEN
    RAISE EXCEPTION 'Bu tür için yalnızca 1 görsel eklenebilir.';
  ELSIF c >= 10 THEN
    RAISE EXCEPTION 'Carousel için en fazla 10 görsel eklenebilir.';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER trg_plan_media_limit BEFORE INSERT ON plan_media
  FOR EACH ROW EXECUTE FUNCTION enforce_media_limit();

-- =====================================================================
--  GÖRÜNÜMLER (sitenin sık kullandığı sorgular)
-- =====================================================================

-- İçerikler tablosu: tek satırda özet
CREATE VIEW v_content_list AS
SELECT c.id, c.account_id, c.title, c.published_on,
       m.views, m.viewers, m.avg_watch_s, m.likes,
       (SELECT r.value_pct FROM content_rates r WHERE r.content_id = c.id AND r.kind = 'skip') AS skip_pct,
       m.followers_pct
FROM contents c
LEFT JOIN content_metrics m ON m.content_id = c.id;

-- Üstteki istatistik kartları
CREATE VIEW v_account_stats AS
SELECT c.account_id,
       count(*)                       AS content_count,
       coalesce(sum(m.views), 0)      AS total_views,
       coalesce(sum(m.likes), 0)      AS total_likes,
       round(avg(m.avg_watch_s), 1)   AS avg_watch_s
FROM contents c
LEFT JOIN content_metrics m ON m.content_id = c.id
GROUP BY c.account_id;

-- Takvim hücreleri: plan + kapak görseli + görsel sayısı
CREATE VIEW v_calendar AS
SELECT p.id, p.account_id, p.planned_date, p.planned_time, p.type, p.status, p.title, p.note,
       (SELECT storage_path FROM plan_media WHERE plan_id = p.id ORDER BY position LIMIT 1) AS cover_path,
       (SELECT count(*)     FROM plan_media WHERE plan_id = p.id)                           AS media_count
FROM publish_plans p;

-- Fikirler: etiketler tek metinde (Excel dışa aktarma için)
CREATE VIEW v_ideas_export AS
SELECT i.id, i.account_id, i.title, i.note, i.status,
       coalesce(string_agg(t.name, ', ' ORDER BY t.name), '') AS tags
FROM ideas i
LEFT JOIN idea_tags it ON it.idea_id = i.id
LEFT JOIN tags t       ON t.id = it.tag_id
GROUP BY i.id;

-- =====================================================================
--  SATIR DÜZEYİ GÜVENLİK (Supabase / PostgreSQL RLS)
--  Her kullanıcı yalnızca kendi hesaplarının verisini görür.
--  auth.uid() Supabase'e özgüdür; başka bir ortamda kendi oturum
--  fonksiyonunuzla değiştirin.
-- =====================================================================
-- ALTER TABLE accounts       ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE contents       ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE ideas          ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE publish_plans  ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY own_accounts ON accounts      USING (user_id = auth.uid());
-- CREATE POLICY own_contents ON contents      USING (account_id IN (SELECT id FROM accounts WHERE user_id = auth.uid()));
-- CREATE POLICY own_ideas    ON ideas         USING (account_id IN (SELECT id FROM accounts WHERE user_id = auth.uid()));
-- CREATE POLICY own_plans    ON publish_plans USING (account_id IN (SELECT id FROM accounts WHERE user_id = auth.uid()));
-- (Alt tablolar için aynı mantıkla, üst kayıt üzerinden politika yazılır.)

COMMIT;
