-- 在事务中模拟后续期望 Schema 和更早的存量 Schema，回滚后不影响部署验证。
BEGIN;

-- 未来的新库先完成 Step 0；040 不得将这些 CHECK 缩回旧列表。
ALTER TABLE kbd_batch_job DROP CONSTRAINT ck_kbd_batch_job_status;
ALTER TABLE kbd_batch_job ADD CONSTRAINT ck_kbd_batch_job_status
  CHECK (status IN ('pending','running','completed','partial_failed','failed','interrupted','queued'));
ALTER TABLE kbd_batch_job DROP CONSTRAINT ck_kbd_batch_job_type;
ALTER TABLE kbd_batch_job ADD CONSTRAINT ck_kbd_batch_job_type
  CHECK (job_type IN ('reanalyze_images','reclassify','extract_signals','approve','reject','future_job'));
ALTER TABLE kbd_batch_job DROP CONSTRAINT ck_kbd_batch_job_counts;
ALTER TABLE kbd_batch_job ADD CONSTRAINT ck_kbd_batch_job_counts CHECK (
  total_count >= 0 AND completed_count >= 0 AND succeeded_count >= 0 AND failed_count >= 0
  AND interrupted_count >= 0 AND completed_count = succeeded_count + failed_count + interrupted_count
  AND completed_count <= total_count);
ALTER TABLE kbd_batch_job_item DROP CONSTRAINT ck_kbd_batch_job_item_status;
ALTER TABLE kbd_batch_job_item ADD CONSTRAINT ck_kbd_batch_job_item_status
  CHECK (status IN ('pending','running','succeeded','failed','interrupted','queued'));
CREATE TEMP TABLE expected_checks AS
  SELECT oid, conrelid, conname, pg_get_constraintdef(oid) AS definition FROM pg_constraint
  WHERE (conrelid = 'public.kbd_batch_job'::regclass
    AND conname IN ('ck_kbd_batch_job_status','ck_kbd_batch_job_type','ck_kbd_batch_job_counts'))
    OR (conrelid = 'public.kbd_batch_job_item'::regclass AND conname = 'ck_kbd_batch_job_item_status');

-- 同名的其他 schema 列不能阻止 public.message 补齐 tool_call_id。
CREATE SCHEMA ptah_repair_shadow;
CREATE TABLE ptah_repair_shadow.message (tool_call_id text);
ALTER TABLE public.message DROP COLUMN tool_call_id;
\ir /data-migrations/040_preserve_legacy_extras_repairs.sql

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM expected_checks e LEFT JOIN pg_constraint c ON c.oid = e.oid
    WHERE c.oid IS NULL OR pg_get_constraintdef(c.oid) <> e.definition) THEN
    RAISE EXCEPTION '040 重建或收窄了后续 Schema 的 CHECK';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'message' AND column_name = 'tool_call_id') THEN
    RAISE EXCEPTION '其他 schema 的同名列阻止了 public.message 修复';
  END IF;
END $$;

-- 模拟 041 在最终 Schema 收敛之前使用新值；旧列表或旧 counts 会使此处失败。
INSERT INTO kbd_batch_job(batch_id,job_type,status,requested_kbd_ids,total_count,trace_id)
VALUES('00000000-0000-4000-8000-000000000041','future_job','queued','[]',0,'ptah-future-migration');
INSERT INTO kbd_entry(support_id,title) VALUES('ptah-legacy-repair','遗留修复回归');
INSERT INTO kbd_batch_job_item(batch_id,kbd_id,status,trace_id)
SELECT '00000000-0000-4000-8000-000000000041',id,'queued','ptah-future-item'
FROM kbd_entry WHERE support_id = 'ptah-legacy-repair';
DELETE FROM kbd_batch_job WHERE batch_id = '00000000-0000-4000-8000-000000000041';

-- 还原已知旧约束，验证 guard 没有丢掉存量库所需的扩展和中断数据转换。
ALTER TABLE kbd_batch_job DROP CONSTRAINT ck_kbd_batch_job_status;
ALTER TABLE kbd_batch_job ADD CONSTRAINT ck_kbd_batch_job_status
  CHECK (status IN ('pending','running','completed','partial_failed','failed'));
ALTER TABLE kbd_batch_job DROP CONSTRAINT ck_kbd_batch_job_type;
ALTER TABLE kbd_batch_job ADD CONSTRAINT ck_kbd_batch_job_type
  CHECK (job_type IN ('reanalyze_images','reclassify','approve','reject'));
ALTER TABLE kbd_batch_job DROP CONSTRAINT ck_kbd_batch_job_counts;
ALTER TABLE kbd_batch_job ADD CONSTRAINT ck_kbd_batch_job_counts CHECK (
  total_count > 0 AND completed_count >= 0 AND succeeded_count >= 0 AND failed_count >= 0
  AND completed_count = succeeded_count + failed_count AND completed_count <= total_count);
ALTER TABLE kbd_batch_job_item DROP CONSTRAINT ck_kbd_batch_job_item_status;
ALTER TABLE kbd_batch_job_item ADD CONSTRAINT ck_kbd_batch_job_item_status
  CHECK (status IN ('pending','running','succeeded','failed'));
INSERT INTO kbd_batch_job(batch_id,job_type,status,requested_kbd_ids,total_count,
  completed_count,failed_count,trace_id)
VALUES('00000000-0000-4000-8000-000000000040','reclassify','failed','[]',1,1,1,'ptah-legacy-repair');
INSERT INTO kbd_batch_job_item(batch_id,kbd_id,status,error_json,trace_id)
SELECT '00000000-0000-4000-8000-000000000040',id,'failed',
  '{"code":"BATCH_PROCESS_INTERRUPTED"}','ptah-legacy-item'
FROM kbd_entry WHERE support_id = 'ptah-legacy-repair';
\ir /data-migrations/040_preserve_legacy_extras_repairs.sql

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM kbd_batch_job WHERE trace_id = 'ptah-legacy-repair'
    AND status = 'interrupted' AND interrupted_count = 1 AND failed_count = 0) THEN
    RAISE EXCEPTION '040 未修复旧约束下的中断任务';
  END IF;
END $$;
UPDATE kbd_batch_job SET job_type = 'extract_signals' WHERE trace_id = 'ptah-legacy-repair';
ROLLBACK;
