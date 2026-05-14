-- 0008_room_queue.sql
-- 再生キュー(§2.15 / §3 v1.1 機能)用テーブル。Shared モードでは両端末で
-- last-write-wins の共有キューを持ち、Solo モードはアプリ側で in-memory のみ
-- 保持してこのテーブルには書き込まない。
--
-- 背景:
--   QueueSheet で「次に再生」リストを Shared 時にペア間で即時同期するために、
--   shared_room.id を `room_id` として参照する row を CRUD する。Realtime publication
--   に追加することで、両端末で postgres_changes をリッスンして反映する。
--
-- 仕様:
--   - 順序: position INTEGER で管理(0 ベース昇順)。並べ替え時は両端の差分行を
--     UPDATE する想定。
--   - 追加者: added_by に profiles.id を保持(キュー行のアバター表示用)
--   - 操作権限: shared_room なら pair_relationships の当事者(active)、my_room なら
--     その所有者(profiles.my_room_id = r.id)が SELECT/INSERT/UPDATE/DELETE 可能
--     (現状 Solo は in-memory なので my_room ポリシーはほぼ未使用だが、将来の
--     永続化に備えて用意しておく)
--
-- 関連: PairTune_Design_Handoff_v0.4.md §2.15, PairTune_Specification_v0.4.md §3

CREATE TABLE IF NOT EXISTS room_queue (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  position INTEGER NOT NULL,

  -- 曲情報(Apple Music カタログから保存)
  song_id TEXT NOT NULL,
  song_title TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  album_title TEXT,
  artwork_url TEXT,
  duration_seconds INTEGER,

  -- 追加情報
  added_by UUID REFERENCES profiles(id) ON DELETE SET NULL,
  added_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_room_queue_room_position
  ON room_queue(room_id, position);
CREATE INDEX IF NOT EXISTS idx_room_queue_added_at
  ON room_queue(room_id, added_at DESC);

ALTER TABLE room_queue ENABLE ROW LEVEL SECURITY;

-- 6.8: room_queue ポリシー(shared / my の双方をカバー)
DROP POLICY IF EXISTS "Members can manage queue" ON room_queue;
CREATE POLICY "Members can manage queue"
  ON room_queue
  FOR ALL
  USING (
    -- shared_room: 当事者(active) なら OK
    EXISTS (
      SELECT 1 FROM pair_relationships pr
      WHERE pr.shared_room_id = room_queue.room_id
        AND pr.status = 'active'
        AND (pr.user_a_id = auth.uid() OR pr.user_b_id = auth.uid())
    )
    OR
    -- my_room: 所有者なら OK
    EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid() AND p.my_room_id = room_queue.room_id
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM pair_relationships pr
      WHERE pr.shared_room_id = room_queue.room_id
        AND pr.status = 'active'
        AND (pr.user_a_id = auth.uid() OR pr.user_b_id = auth.uid())
    )
    OR
    EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = auth.uid() AND p.my_room_id = room_queue.room_id
    )
  );

-- 6.9: 「次に再生」用の position シフト RPC
-- after_position より大きい position の行を +1 シフトすることで、afterPosition+1 に
-- 新規行を挿入できるスペースを開ける。race 時の position 衝突は許容(MVP)。
CREATE OR REPLACE FUNCTION shift_queue_positions(
  p_room_id UUID,
  p_from_position INTEGER
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  -- 当事者チェック(SECURITY DEFINER 経由でも自分が居る room しか触れない)
  IF NOT EXISTS (
    SELECT 1 FROM pair_relationships pr
    WHERE pr.shared_room_id = p_room_id
      AND pr.status = 'active'
      AND (pr.user_a_id = auth.uid() OR pr.user_b_id = auth.uid())
  ) AND NOT EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = auth.uid() AND p.my_room_id = p_room_id
  ) THEN
    RAISE EXCEPTION 'Not authorized for this room';
  END IF;

  UPDATE room_queue
  SET position = position + 1
  WHERE room_id = p_room_id
    AND position >= p_from_position;
END;
$$;


-- Realtime publication に追加(両端末の postgres_changes リッスン用)。
-- 既に追加されていればエラーにせずスキップする。
DO $$
BEGIN
  BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE room_queue;
  EXCEPTION WHEN duplicate_object THEN
    -- 既に追加済み
    NULL;
  END;
END$$;
