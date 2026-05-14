-- 0006_merge_history_on_repair.sql
-- 同じカップル(A, B)が解除→再ペアリングした時に、旧 shared_room_play_history を
-- 新しい pair_id にマージする。
--
-- 背景:
--   pair_relationships は (user_a_id, user_b_id) が UNIQUE なのは status='active' の時だけで、
--   解除すると ended 行が残り、再ペアリング時に新しい active 行 + 新しい shared_room が作られる。
--   そのため再ペアリング後の Solo 画面「ふたりで聴いた曲」は active pair_id 配下のみ参照され、
--   過去の履歴は事実上見えなくなる(別の pair_id 配下にあるため)。
--
-- 対応:
--   accept_pair_request() の最後に「同じカップルの ended かつ preserve_memories=TRUE な
--   pair_relationships の shared_room_play_history.pair_id を新 pair_id に書き換える」処理を追加。
--   - shared_room_id は元の値のまま(セッションの同一性を保つため)
--   - pair_milestones は移行しない(節目イベントは関係期間に紐づくため、新ペアでは新規検出)
--   - 旧 pair_relationships 行はそのまま ended 状態で残る(解除イベントの履歴として保持)
--
-- 影響:
--   - 履歴は新 pair_id 配下に集約されるので、SoloHistoryViewModel.loadSharedHistory の
--     クエリ (.eq("pair_id", active_pair_id)) はそのままで OK
--   - preserve_memories=FALSE で解除した場合は cleanup_ended_pairs() で物理削除されるため、
--     マージ対象に含まれない(過去の意思を尊重)
--
-- 関連: PairTune_Specification_v0.4.md §7-8, docs/PairTune_DB_Schema.sql 5.2

CREATE OR REPLACE FUNCTION accept_pair_request(p_request_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_request pair_requests%ROWTYPE;
  v_user_a UUID;
  v_user_b UUID;
  v_shared_room_id UUID;
  v_pair_id UUID;
  v_merged_count INTEGER;
BEGIN
  -- 申請を取得
  SELECT * INTO v_request FROM pair_requests WHERE id = p_request_id;

  IF v_request.status != 'pending' THEN
    RAISE EXCEPTION 'Request is not pending';
  END IF;

  IF v_request.expires_at < NOW() THEN
    UPDATE pair_requests SET status = 'expired' WHERE id = p_request_id;
    RAISE EXCEPTION 'Request has expired';
  END IF;

  -- A < B に並べ替え (ordered_pair 制約のため)
  IF v_request.requester_id < v_request.target_id THEN
    v_user_a := v_request.requester_id;
    v_user_b := v_request.target_id;
  ELSE
    v_user_a := v_request.target_id;
    v_user_b := v_request.requester_id;
  END IF;

  -- shared_room 作成
  INSERT INTO rooms (room_type) VALUES ('shared_room')
  RETURNING id INTO v_shared_room_id;

  -- pair_relationships 作成
  INSERT INTO pair_relationships (user_a_id, user_b_id, shared_room_id)
  VALUES (v_user_a, v_user_b, v_shared_room_id)
  RETURNING id INTO v_pair_id;

  -- 両者の active_pair_id を更新
  UPDATE profiles SET active_pair_id = v_pair_id
  WHERE id IN (v_user_a, v_user_b);

  -- 申請を accepted に
  UPDATE pair_requests
  SET status = 'accepted', responded_at = NOW()
  WHERE id = p_request_id;

  -- ★ 旧履歴マージ:
  --   同じ (user_a_id, user_b_id) の ended pair で preserve_memories=TRUE のものに紐づく
  --   shared_room_play_history を新 pair_id へ集約する。
  WITH old_pairs AS (
    SELECT id FROM pair_relationships
    WHERE status = 'ended'
      AND preserve_memories = TRUE
      AND user_a_id = v_user_a
      AND user_b_id = v_user_b
  )
  UPDATE shared_room_play_history
  SET pair_id = v_pair_id
  WHERE pair_id IN (SELECT id FROM old_pairs);

  GET DIAGNOSTICS v_merged_count = ROW_COUNT;
  RAISE NOTICE 'accept_pair_request: merged % old history rows into pair %', v_merged_count, v_pair_id;

  RETURN v_pair_id;
END;
$$;
