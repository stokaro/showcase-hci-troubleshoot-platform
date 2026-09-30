-- Verify the complete upstream object inventory and application behavior.
BEGIN;
DO $$
DECLARE
  owner_id uuid;
  conversation_key uuid;
  message_key uuid;
  case_number varchar;
  next_case_number varchar;
  actual integer;
BEGIN
  SELECT count(*) INTO actual FROM pg_tables WHERE schemaname='public';
  IF actual <> 76 THEN RAISE EXCEPTION 'Expected 76 tables, got %', actual; END IF;
  SELECT count(*) INTO actual FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND NOT EXISTS
      (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e');
  IF actual <> 4 THEN RAISE EXCEPTION 'Expected 4 application functions, got %', actual; END IF;
  SELECT count(*) INTO actual FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgenabled='O';
  IF actual <> 24 THEN RAISE EXCEPTION 'Expected 24 enabled triggers, got %', actual; END IF;
  SELECT count(*) INTO actual FROM pg_extension
    WHERE extname IN ('vector','pgcrypto','uuid-ossp','pg_trgm');
  IF actual <> 4 THEN RAISE EXCEPTION 'Missing a declared extension'; END IF;
  SELECT count(*) INTO actual FROM pg_class c JOIN pg_index i ON i.indexrelid=c.oid
    JOIN pg_am a ON a.oid=c.relam
    WHERE c.relname IN ('idx_kb_category_embedding','idx_kbd_entry_embedding')
      AND a.amname='ivfflat' AND c.reloptions @> ARRAY['lists=100'] AND i.indisvalid;
  IF actual <> 2 THEN RAISE EXCEPTION 'IVFFlat index definitions were not retained'; END IF;
  IF '[1,0,0]'::vector <=> '[1,0,0]'::vector <> 0 THEN
    RAISE EXCEPTION 'pgvector cosine distance failed';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sop_execution'
      AND column_name='pending_variable_name' AND column_default IS NOT NULL) THEN
    RAISE EXCEPTION 'pending_variable_name must retain its implicit SQL NULL default';
  END IF;

  INSERT INTO "user"(client_id,updated_at) VALUES ('ptah-functional-test','2000-01-01')
    RETURNING user_id INTO owner_id;
  UPDATE "user" SET username='trigger-test' WHERE user_id=owner_id;
  IF (SELECT updated_at FROM "user" WHERE user_id=owner_id) <> CURRENT_TIMESTAMP THEN
    RAISE EXCEPTION 'updated_at trigger did not fire';
  END IF;
  case_number := generate_case_id();
  IF case_number !~ '^Q[0-9]{13}$' THEN RAISE EXCEPTION 'Invalid generated case ID'; END IF;
  INSERT INTO "case"(case_id,user_id,client_id,title)
    VALUES(case_number,owner_id,'ptah-functional-test','Schema behavior test');
  next_case_number := generate_case_id();
  IF next_case_number=case_number THEN RAISE EXCEPTION 'Case number did not advance'; END IF;
  INSERT INTO conversation(case_id) VALUES(case_number) RETURNING conversation_id INTO conversation_key;
  INSERT INTO message(conversation_id,case_id,role,content)
    VALUES(conversation_key,case_number,'user','Message counter test') RETURNING message_id INTO message_key;
  IF (SELECT message_count FROM conversation WHERE conversation_id=conversation_key) <> 1 THEN
    RAISE EXCEPTION 'Message INSERT was not counted exactly once';
  END IF;
  DELETE FROM message WHERE message_id=message_key;
  IF (SELECT message_count FROM conversation WHERE conversation_id=conversation_key) <> 0 THEN
    RAISE EXCEPTION 'Message DELETE did not restore the counter';
  END IF;
END $$;
ROLLBACK;
