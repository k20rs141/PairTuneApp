-- 0009_room_queue_replica_identity.sql
-- room_queue の DELETE イベントが Realtime で `filter: room_id=eq.X` 経由で
-- 配信されない問題を修正する。
--
-- 背景:
--   Supabase Realtime の postgres_changes は、デフォルト REPLICA IDENTITY(PK のみ)
--   だと DELETE イベントの payload に主キー列しか含まれない。よってクライアントが
--   `filter: room_id=eq.<id>` で購読していても、room_id が payload に無いため
--   DELETE 通知が一切配信されなかった(端末 A で削除しても、端末 B の QueueSheet /
--   キューバッジが更新されないバグ)。
--
-- 対応:
--   ALTER TABLE room_queue REPLICA IDENTITY FULL で全列を WAL に記録する。
--   これにより DELETE の old_record にも room_id 等の全列が入り、filter が効くようになる。
--
-- コスト:
--   WAL サイズが若干増える。room_queue は曲単位の小さな行で行数も限定的なので影響軽微。

ALTER TABLE room_queue REPLICA IDENTITY FULL;
