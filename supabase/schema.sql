-- TimeTrack2 云同步 schema（模块 2c）
-- 字段与本地 drift 表一致（镜像关系，见 AGENTS.md 计划 #14）；时间列存带偏移
-- 的 UTC ISO8601 文本（与本地 utcString 格式一致，字典序 = 时间序，可字符串比较）。
--
-- 核心语义（与本地不变量一致）：
-- - 软删统一 deleted_at 时间戳（可空）；删除永远赢（LWW 靠 updated_at，无独立删除列表）
-- - LWW 比较基于 updated_at（服务端比较在触发器/应用层，客户端拉推已做 LWW）
-- - 分类层级 parent_id 自引用；删除父分类递归软删子孙（触发器，WITH RECURSIVE）
--   + 子孙 updated_at 用 greatest(自身, 父行) 保持 LWW 传播（父删除时间 ≥ 子，保证
--   远端副本判定时父删除事件不落后于子行，防"子复活"）
-- - RLS：每行 user_id = auth.uid()；外键存在性显式校验（触发器）
--
-- 增量索引：(user_id, updated_at)（云同步 since 游标查询）。

-- =============================================================
-- 触发器辅助函数
-- =============================================================

-- 校验外键引用存在且未被软删（soft delete 体系下 FK 只约束物理存在；
-- 但同步包/客户端可能携带悬挂引用，云端写入前显式校验，防脏数据入库）。
-- 空串引用一律拒绝（NOT NULL 列上的 '' 是悬挂引用，不得放行）。
CREATE OR REPLACE FUNCTION assert_ref_exists(ref_table TEXT, ref_id TEXT)
RETURNS void AS $$
DECLARE
  exists_id TEXT;
BEGIN
  IF ref_id IS NULL THEN
    RETURN;
  END IF;
  IF ref_id = '' THEN
    RAISE EXCEPTION 'empty reference id for % is invalid', ref_table;
  END IF;
  -- FOR KEY SHARE 行锁：阻塞并发软删（UPDATE deleted_at），防"检查后、提交前
  -- 被引用行被删"的 TOCTOU 竞态。
  EXECUTE format(
    'SELECT id FROM %I WHERE id = $1 AND deleted_at IS NULL FOR KEY SHARE',
    ref_table
  ) INTO exists_id USING ref_id;
  IF exists_id IS NULL THEN
    RAISE EXCEPTION 'referenced % row % does not exist or is soft-deleted',
      ref_table, ref_id;
  END IF;
END;
$$ LANGUAGE plpgsql;

-- 读取带格式化的时间（UTC ISO8601 文本）
CREATE OR REPLACE FUNCTION now_utc_iso()
RETURNS text AS $$
BEGIN
  RETURN to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
END;
$$ LANGUAGE plpgsql;

-- =============================================================
-- 表结构
-- =============================================================

-- 活动（事项）
CREATE TABLE IF NOT EXISTS activities (
  id          text PRIMARY KEY,
  user_id     uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  name        text NOT NULL,
  color       bigint NOT NULL DEFAULT 0xff64748b,
  is_favorite boolean NOT NULL DEFAULT true,
  updated_at  text NOT NULL,
  deleted_at  text,
  is_unassigned boolean NOT NULL DEFAULT false,
  is_one_off    boolean NOT NULL DEFAULT false
);

-- 活动分类（parent_id 自引用层级）
CREATE TABLE IF NOT EXISTS activity_categories (
  id        text PRIMARY KEY,
  user_id   uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  name      text NOT NULL,
  color     bigint NOT NULL DEFAULT 0xff0f766e,
  updated_at text NOT NULL,
  deleted_at text,
  parent_id text REFERENCES activity_categories(id)
);

-- 活动-分类关联
CREATE TABLE IF NOT EXISTS activity_category_links (
  id          text PRIMARY KEY,
  user_id     uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  activity_id text NOT NULL,
  category_id text NOT NULL,
  is_primary  boolean NOT NULL DEFAULT false,
  sort_order  integer NOT NULL DEFAULT 0,
  updated_at  text NOT NULL,
  deleted_at  text
);

-- 时间条目
CREATE TABLE IF NOT EXISTS time_entries (
  id             text PRIMARY KEY,
  user_id        uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  activity_id    text NOT NULL,
  activity_name  text NOT NULL DEFAULT '',
  activity_color integer,
  start_at       text NOT NULL,
  end_at         text,
  note           text NOT NULL DEFAULT '',
  device_id      text NOT NULL,
  updated_at     text NOT NULL,
  deleted_at     text
);

-- 操作日志
-- 注意：activity_id / entry_id 为可空的归档性引用，**有意不做存在性校验**
--（日志容忍脏引用：活动/条目被删后历史日志仍保留其 id 供展示，校验会
-- 阻止删除后追加的日志写入）。与 time_entries/links 的强制校验模式不同。
CREATE TABLE IF NOT EXISTS action_logs (
  id          text PRIMARY KEY,
  user_id     uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  action_type text NOT NULL,
  activity_id text,
  entry_id    text,
  message     text NOT NULL DEFAULT '',
  occurred_at text NOT NULL,
  device_id   text NOT NULL,
  updated_at  text NOT NULL,
  deleted_at  text
);

-- 配置（每用户单例：user_id 为主键，客户端配置无 id 字段——PostgREST
-- merge-duplicates 按 user_id 合并，防重复插入）。
CREATE TABLE IF NOT EXISTS profile_settings (
  user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  reminder_minutes integer NOT NULL DEFAULT 45,
  reminder_interval_minutes integer NOT NULL DEFAULT 10,
  reminder_method text NOT NULL DEFAULT 'dialog',
  reminder_time_of_day_minutes integer NOT NULL DEFAULT 540,
  merge_neighbor_threshold_minutes integer NOT NULL DEFAULT 1,
  timezone text NOT NULL DEFAULT 'UTC',
  updated_at text NOT NULL
);

-- =============================================================
-- 增量索引（云同步 since 游标查询）
-- =============================================================
CREATE INDEX IF NOT EXISTS idx_activities_sync
  ON activities (user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_activity_categories_sync
  ON activity_categories (user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_activity_category_links_sync
  ON activity_category_links (user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_time_entries_sync
  ON time_entries (user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_action_logs_sync
  ON action_logs (user_id, updated_at);
CREATE INDEX IF NOT EXISTS idx_profile_settings_sync
  ON profile_settings (user_id, updated_at);

-- 分类 parent_id 递归查询索引（穿透已删节点）
CREATE INDEX IF NOT EXISTS idx_activity_categories_parent
  ON activity_categories (parent_id);

-- links 按 category_id 索引（分类软删级联 UPDATE ... WHERE category_id = ...，
-- 避免全表扫描）
CREATE INDEX IF NOT EXISTS idx_activity_category_links_category
  ON activity_category_links (category_id);

-- =============================================================
-- 触发器：父分类递归软删（删除永远赢 + greatest() LWW 传播）
-- =============================================================

CREATE OR REPLACE FUNCTION soft_delete_activity_category_children()
RETURNS trigger AS $$
DECLARE
  descendant RECORD;
  parent_ts text;
BEGIN
  IF NEW.deleted_at IS NULL THEN
    RETURN NEW;
  END IF;
  parent_ts := NEW.updated_at;
  -- 递归收集子孙（WITH RECURSIVE 穿透已删节点，UNION 防环）。
  FOR descendant IN
    WITH RECURSIVE tree AS (
      SELECT id, parent_id FROM activity_categories WHERE parent_id = NEW.id
      UNION
      SELECT c.id, c.parent_id
        FROM activity_categories c
        JOIN tree t ON c.parent_id = t.id
    )
    SELECT t.id FROM tree t
  LOOP
    -- 子孙 deleted_at 置为父删除时刻；updated_at 用 greatest(自身, 父)：
    -- 保证父删除事件不落后于任何子行（远端 LWW 判定时子行"更旧"，
    -- 删除必然传播，防子复活）。
    UPDATE activity_categories
      SET deleted_at = parent_ts,
          updated_at = CASE
            WHEN updated_at > parent_ts THEN updated_at
            ELSE parent_ts
          END
      WHERE id = descendant.id AND deleted_at IS NULL;
  END LOOP;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_activity_category_soft_delete
AFTER UPDATE OF deleted_at ON activity_categories
FOR EACH ROW
WHEN (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL)
EXECUTE FUNCTION soft_delete_activity_category_children();

-- 关联表级联软删（分类被删时其 links 一并软删，same updated_at 传播）
CREATE OR REPLACE FUNCTION soft_delete_category_links()
RETURNS trigger AS $$
BEGIN
  IF NEW.deleted_at IS NULL THEN
    RETURN NEW;
  END IF;
  UPDATE activity_category_links
    SET deleted_at = NEW.updated_at,
        updated_at = CASE
          WHEN updated_at > NEW.updated_at THEN updated_at
          ELSE NEW.updated_at
        END
    WHERE category_id = NEW.id AND deleted_at IS NULL;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_activity_category_links_soft_delete
AFTER UPDATE OF deleted_at ON activity_categories
FOR EACH ROW
WHEN (NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL)
EXECUTE FUNCTION soft_delete_category_links();

-- =============================================================
-- 触发器：写入前外键存在性显式校验
-- =============================================================

-- =============================================================
-- 触发器：写入前外键存在性显式校验
--
-- 关键：**软删 UPDATE（NEW.deleted_at 非空）跳过引用校验**——软删只置
-- deleted_at/updated_at，不改变 activity_id/category_id/parent_id 等引用字段，
-- 引用完整性由 INSERT 与活跃 UPDATE 保证。若软删也校验，级联软删（父分类删除
-- 时 UPDATE 子孙/links）会因被引用行已软删而在 BEFORE UPDATE 抛异常，导致
-- 整个级联连同用户的原始软删一起回滚——"删除永远赢"语义失效。
-- =============================================================

CREATE OR REPLACE FUNCTION validate_time_entry_ref()
RETURNS trigger AS $$
BEGIN
  -- 软删不改变引用关系：跳过校验（防被引用活动已软删时条目无法软删）。
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  PERFORM assert_ref_exists('activities', NEW.activity_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_time_entries_ref_check
BEFORE INSERT OR UPDATE ON time_entries
FOR EACH ROW EXECUTE FUNCTION validate_time_entry_ref();

CREATE OR REPLACE FUNCTION validate_link_ref()
RETURNS trigger AS $$
BEGIN
  -- 软删不改变引用关系：跳过校验（防分类级联软删 links 时 category 已软删）。
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  PERFORM assert_ref_exists('activities', NEW.activity_id);
  PERFORM assert_ref_exists('activity_categories', NEW.category_id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_activity_category_links_ref_check
BEFORE INSERT OR UPDATE ON activity_category_links
FOR EACH ROW EXECUTE FUNCTION validate_link_ref();

CREATE OR REPLACE FUNCTION validate_category_parent_ref()
RETURNS trigger AS $$
BEGIN
  -- 软删不改变引用关系：跳过校验（防父分类级联软删子孙时父已软删，
  -- 递归 CTE 更新子孙的 BEFORE UPDATE 抛异常导致整个级联回滚）。
  IF NEW.deleted_at IS NOT NULL THEN
    RETURN NEW;
  END IF;
  IF NEW.parent_id IS NOT NULL THEN
    PERFORM assert_ref_exists('activity_categories', NEW.parent_id);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_activity_categories_parent_ref_check
BEFORE INSERT OR UPDATE ON activity_categories
FOR EACH ROW EXECUTE FUNCTION validate_category_parent_ref();

-- =============================================================
-- RLS（行级安全：每行 user_id = auth.uid()）
-- =============================================================

ALTER TABLE activities ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_category_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE time_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE action_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE profile_settings ENABLE ROW LEVEL SECURITY;

-- 策略：用户只能读写自己的行（写入强制 user_id = auth.uid()，防越权写他人数据）
CREATE POLICY activities_all_own ON activities
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
CREATE POLICY activity_categories_all_own ON activity_categories
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
CREATE POLICY activity_category_links_all_own ON activity_category_links
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
CREATE POLICY time_entries_all_own ON time_entries
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
CREATE POLICY action_logs_all_own ON action_logs
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
CREATE POLICY profile_settings_all_own ON profile_settings
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
