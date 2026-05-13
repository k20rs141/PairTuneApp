-- 0005_cancel_pair_request.sql
-- 申請者(A 側)から pair_request をキャンセル可能にする。
--
-- 背景:
--   現状の RLS では pair_requests への UPDATE は target_id(B 側)しか許可されておらず、
--   申請を出した A 側が自分の申請を取り消す手段が無い。クライアント側でローカル state を
--   クリアしても DB は pending のままなので、B 側が承認すれば勝手にペアが成立してしまう。
--
-- 対応:
--   - pair_requests.status の CHECK 制約に 'cancelled' を追加
--     (※ status は ENUM ではなく TEXT + CHECK で実装されている)
--   - SECURITY DEFINER の cancel_pair_request(p_request_id) RPC を追加
--     - auth.uid() = requester_id を検証
--     - status = 'pending' のみ取消可能
--     - status='cancelled', responded_at=NOW() に更新
--   - accept_pair_request は既に `status != 'pending'` を弾く実装なので、自動的に
--     cancelled な申請は承認できなくなる(追加の変更不要)

-- 1. CHECK 制約を 'cancelled' を含むように張り直す
ALTER TABLE pair_requests DROP CONSTRAINT IF EXISTS pair_requests_status_check;
ALTER TABLE pair_requests ADD CONSTRAINT pair_requests_status_check
  CHECK (status IN ('pending', 'accepted', 'rejected', 'expired', 'cancelled'));

-- 2. cancel_pair_request RPC
CREATE OR REPLACE FUNCTION cancel_pair_request(p_request_id UUID)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_request pair_requests%ROWTYPE;
BEGIN
  SELECT * INTO v_request FROM pair_requests WHERE id = p_request_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'REQUEST_NOT_FOUND';
  END IF;

  IF v_request.requester_id != auth.uid() THEN
    RAISE EXCEPTION 'NOT_OWNER';
  END IF;

  IF v_request.status != 'pending' THEN
    RAISE EXCEPTION 'NOT_PENDING';
  END IF;

  UPDATE pair_requests
  SET status = 'cancelled', responded_at = NOW()
  WHERE id = p_request_id;
END;
$$;

GRANT EXECUTE ON FUNCTION cancel_pair_request(UUID) TO authenticated;
