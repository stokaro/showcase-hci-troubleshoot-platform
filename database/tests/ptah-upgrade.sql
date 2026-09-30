-- Add representative existing rows and obsolete Alembic objects to the upstream schema.
INSERT INTO "user"(client_id,metadata)
VALUES('ptah-upgrade-sentinel','{"preserve":"user-data"}');
INSERT INTO kbd_entry(support_id,title)
VALUES('ptah-upgrade-kbd','Existing knowledge article');
INSERT INTO bundle_metadata(kbd_id,support_id,bundle_digest,factory_version,compiler_revision)
SELECT id,support_id,'ptah-upgrade-digest','original-factory','original-revision'
FROM kbd_entry WHERE support_id='ptah-upgrade-kbd';
INSERT INTO kbd_batch_job(batch_id,job_type,status,requested_kbd_ids,total_count,
  completed_count,failed_count,trace_id)
VALUES('00000000-0000-4000-8000-000000000001','extract_signals','failed','[]',1,1,1,'ptah-upgrade-batch');
INSERT INTO kbd_batch_job_item(batch_id,kbd_id,status,error_json,trace_id)
SELECT '00000000-0000-4000-8000-000000000001',id,'failed',
  '{"code":"BATCH_PROCESS_INTERRUPTED"}','ptah-upgrade-item'
FROM kbd_entry WHERE support_id='ptah-upgrade-kbd';

CREATE FUNCTION update_conversation_message_count() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE conversation SET message_count=message_count+1 WHERE conversation_id=NEW.conversation_id;
  RETURN NEW;
END;
$$;
CREATE TRIGGER update_message_count_on_insert AFTER INSERT ON message
  FOR EACH ROW EXECUTE FUNCTION update_conversation_message_count();
CREATE TRIGGER update_message_count_on_delete AFTER DELETE ON message
  FOR EACH ROW EXECUTE FUNCTION update_conversation_message_count();
CREATE TRIGGER trigger_kbd_entry_updated_at BEFORE UPDATE ON kbd_entry
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
