-- 验证完整的上游对象清单及业务行为。
BEGIN;
DO $$
DECLARE
  owner_id uuid;
  conversation_key uuid;
  message_key uuid;
  case_number varchar;
  next_case_number varchar;
  actual integer;
  default_sql text;
  default_is_null boolean;
BEGIN
  SELECT count(*) INTO actual FROM pg_tables WHERE schemaname='public';
  IF actual <> 76 THEN RAISE EXCEPTION '期望 76 张表，实际 %', actual; END IF;
  SELECT count(*) INTO actual FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND NOT EXISTS
      (SELECT 1 FROM pg_depend d WHERE d.classid='pg_proc'::regclass AND d.objid=p.oid AND d.deptype='e');
  IF actual <> 4 THEN RAISE EXCEPTION '期望 4 个应用函数，实际 %', actual; END IF;
  SELECT count(*) INTO actual FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public' AND NOT t.tgisinternal AND t.tgenabled='O';
  IF actual <> 24 THEN RAISE EXCEPTION '期望 24 个启用的触发器，实际 %', actual; END IF;
  SELECT count(*) INTO actual FROM pg_extension
    WHERE extname IN ('vector','pgcrypto','uuid-ossp','pg_trgm');
  IF actual <> 4 THEN RAISE EXCEPTION '缺少声明的扩展'; END IF;
  SELECT count(*) INTO actual FROM pg_class c JOIN pg_index i ON i.indexrelid=c.oid
    JOIN pg_am a ON a.oid=c.relam
    WHERE c.relname IN ('idx_kb_category_embedding','idx_kbd_entry_embedding')
      AND a.amname='ivfflat' AND c.reloptions @> ARRAY['lists=100'] AND i.indisvalid;
  IF actual <> 2 THEN RAISE EXCEPTION 'IVFFlat 索引定义未保留'; END IF;
  IF '[1,0,0]'::vector <=> '[1,0,0]'::vector <> 0 THEN
    RAISE EXCEPTION 'pgvector 余弦距离验证失败';
  END IF;
  SELECT column_default INTO default_sql FROM information_schema.columns
    WHERE table_schema='public' AND table_name='sop_execution'
      AND column_name='pending_variable_name';
  IF default_sql IS NOT NULL THEN
    EXECUTE 'SELECT (' || default_sql || ') IS NULL' INTO default_is_null;
    IF NOT default_is_null THEN
      RAISE EXCEPTION 'pending_variable_name 必须保留 SQL NULL 默认值';
    END IF;
  END IF;

  INSERT INTO "user"(client_id,updated_at) VALUES ('ptah-functional-test','2000-01-01')
    RETURNING user_id INTO owner_id;
  UPDATE "user" SET username='trigger-test' WHERE user_id=owner_id;
  IF (SELECT updated_at FROM "user" WHERE user_id=owner_id) <> CURRENT_TIMESTAMP THEN
    RAISE EXCEPTION 'updated_at 触发器未执行';
  END IF;
  case_number := generate_case_id();
  IF case_number !~ '^Q[0-9]{13}$' THEN RAISE EXCEPTION '生成的工单编号格式错误'; END IF;
  INSERT INTO "case"(case_id,user_id,client_id,title)
    VALUES(case_number,owner_id,'ptah-functional-test','Schema 行为测试');
  next_case_number := generate_case_id();
  IF next_case_number=case_number THEN RAISE EXCEPTION '工单编号未递增'; END IF;
  INSERT INTO conversation(case_id) VALUES(case_number) RETURNING conversation_id INTO conversation_key;
  INSERT INTO message(conversation_id,case_id,role,content)
    VALUES(conversation_key,case_number,'user','消息计数测试') RETURNING message_id INTO message_key;
  IF (SELECT message_count FROM conversation WHERE conversation_id=conversation_key) <> 1 THEN
    RAISE EXCEPTION '消息 INSERT 未准确计数一次';
  END IF;
  DELETE FROM message WHERE message_id=message_key;
  IF (SELECT message_count FROM conversation WHERE conversation_id=conversation_key) <> 0 THEN
    RAISE EXCEPTION '消息 DELETE 未恢复计数';
  END IF;
END $$;
ROLLBACK;
