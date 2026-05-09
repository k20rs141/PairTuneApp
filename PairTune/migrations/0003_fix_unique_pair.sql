-- =============================================================================
-- 0003_fix_unique_pair.sql  (v0.4-M3 hotfix)
-- =============================================================================
-- 背景:
--   pair_relationships.unique_pair は (user_a_id, user_b_id) を無条件 UNIQUE で
--   制約していたため、解消済み(status='ended')のペアと同じ 2 人で再ペアリング
--   しようとすると `duplicate key value violates unique constraint "unique_pair"`
--   が出て accept_pair_request RPC が失敗する。
--
--   仕様 §6 では:
--     - ペアリング解消・再ペアリングは可能
--     - preserve_memories=true なら過去の pair_relationships 行を残し
--       shared_room_play_history (pair_id 参照) を保持する
--   とあるため、過去のペア行は残しつつ「アクティブは 1 つだけ」が正しいセマンティクス。
--
-- 解決:
--   unique_pair を DROP し、status='active' に絞った partial unique index に置換。
--   既に存在する one_active_pair_per_user_a/b と整合性が取れる形。
--
-- 適用順:
--   0001 / 0002 適用済みの環境で実行。冪等。
-- =============================================================================

ALTER TABLE pair_relationships
  DROP CONSTRAINT IF EXISTS unique_pair;

CREATE UNIQUE INDEX IF NOT EXISTS unique_active_pair
  ON pair_relationships (user_a_id, user_b_id)
  WHERE status = 'active';
