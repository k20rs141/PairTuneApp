-- =============================================================================
-- 0002_request_pair_by_code.sql  (v0.4-M3 hotfix)
-- =============================================================================
-- 背景:
--   v0.4-M3 ペアリング申請フローで、A 側が B のコードを入力 →
--   `profiles.pairing_code` で B の user_id を引きたいが、
--   profiles の SELECT ポリシーは「自分自身」「ペア相手」「自分宛 pending 申請の
--   requester」のみ許可しているため、まだペアリングしていない他人を pairing_code
--   で検索することが RLS 的にできない。
--
-- 解決:
--   SECURITY DEFINER の RPC `request_pair_by_code(p_target_code)` を新設し、
--   検索 + 各種検証 + pair_requests への INSERT を 1 トランザクションで行う。
--   profiles の SELECT ポリシーは緩めない(プロフィール一覧の漏洩を防ぐ)。
--
-- 適用順:
--   0001_initial_v04.sql 適用済みの環境に対し、本ファイルを SQL Editor で実行。
-- =============================================================================

CREATE OR REPLACE FUNCTION request_pair_by_code(p_target_code TEXT)
RETURNS pair_requests
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_me UUID;
  v_normalized TEXT;
  v_target_id UUID;
  v_target_active UUID;
  v_my_active UUID;
  v_request pair_requests;
BEGIN
  v_me := auth.uid();
  IF v_me IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED' USING ERRCODE = 'P0001';
  END IF;

  v_normalized := upper(coalesce(p_target_code, ''));
  IF length(v_normalized) <> 6 THEN
    RAISE EXCEPTION 'CODE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  -- 自分の active_pair チェック
  SELECT active_pair_id INTO v_my_active FROM profiles WHERE id = v_me;
  IF v_my_active IS NOT NULL THEN
    RAISE EXCEPTION 'ALREADY_PAIRED' USING ERRCODE = 'P0001';
  END IF;

  -- ターゲット検索 (SECURITY DEFINER なので profile RLS を bypass)
  SELECT id, active_pair_id
    INTO v_target_id, v_target_active
    FROM profiles
   WHERE pairing_code = v_normalized
   LIMIT 1;

  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'CODE_NOT_FOUND' USING ERRCODE = 'P0001';
  END IF;

  IF v_target_id = v_me THEN
    RAISE EXCEPTION 'SELF_PAIR' USING ERRCODE = 'P0001';
  END IF;

  IF v_target_active IS NOT NULL THEN
    RAISE EXCEPTION 'PARTNER_ALREADY_PAIRED' USING ERRCODE = 'P0001';
  END IF;

  -- 既に同相手宛の pending 申請があれば、それを返す (重複申請を再送と見做す)
  SELECT * INTO v_request
    FROM pair_requests
   WHERE requester_id = v_me
     AND target_id = v_target_id
     AND status = 'pending'
   LIMIT 1;

  IF v_request.id IS NOT NULL THEN
    RETURN v_request;
  END IF;

  -- 新規 INSERT
  INSERT INTO pair_requests (requester_id, target_id)
  VALUES (v_me, v_target_id)
  RETURNING * INTO v_request;

  RETURN v_request;
END;
$$;

-- authenticated ロールから実行可能にする (anon は不可)
GRANT EXECUTE ON FUNCTION request_pair_by_code(TEXT) TO authenticated;
