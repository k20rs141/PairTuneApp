-- 0007_update_preserve_memories.sql
-- 解消済み(status='ended')の pair_relationships に対して preserve_memories を
-- 後から変更できるようにする RPC。
--
-- 背景:
--   UnpairDialog の §2.12 では「あとで決める」(preserveMemories=false, 90 日後削除)
--   を選んだユーザーが、後から Profile > Memories > 解消後も思い出を残す トグルで
--   気が変わる可能性がある。現状のスキーマでは pair_relationships への直接 UPDATE は
--   RLS で許可されていないため、SECURITY DEFINER の RPC を 1 本追加する。
--
-- 対応:
--   - update_preserve_memories(p_pair_id UUID, p_preserve BOOLEAN) RPC を新設
--     - 自分(auth.uid())が当事者でない場合は弾く
--     - status='ended' な行のみ対象(active なペアは影響を受けない)
--     - p_preserve = TRUE  : scheduled_deletion_at = NULL(永続保持)
--     - p_preserve = FALSE : 既に値があれば維持、無ければ NOW()+90d を設定
--
-- 関連: PairTune_Specification_v0.4.md §8-5-2, §8-6-2

CREATE OR REPLACE FUNCTION update_preserve_memories(
  p_pair_id UUID,
  p_preserve BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_a UUID;
  v_user_b UUID;
  v_status TEXT;
BEGIN
  SELECT user_a_id, user_b_id, status
  INTO v_user_a, v_user_b, v_status
  FROM pair_relationships
  WHERE id = p_pair_id;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Pair not found';
  END IF;

  -- 当事者チェック(SECURITY DEFINER 経由でも自分の関係性しか触れない)
  IF auth.uid() != v_user_a AND auth.uid() != v_user_b THEN
    RAISE EXCEPTION 'Not a member of this pair';
  END IF;

  IF v_status != 'ended' THEN
    RAISE EXCEPTION 'Pair is not ended (status=%)', v_status;
  END IF;

  UPDATE pair_relationships
  SET preserve_memories = p_preserve,
      scheduled_deletion_at = CASE
        WHEN p_preserve THEN NULL
        ELSE COALESCE(scheduled_deletion_at, NOW() + INTERVAL '90 days')
      END
  WHERE id = p_pair_id;
END;
$$;
