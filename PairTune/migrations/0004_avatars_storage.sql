-- 0004_avatars_storage.sql
-- Profile アバター画像アップロード用の Storage バケット + RLS ポリシー
-- 仕様: docs/PairTune_Specification_v0.4.md §5.5 (Profile / Settings)
-- 実装ガイド: docs/PairTune_Implementation_Guide_v0.4.md §9.7 (Profile image upload)
--
-- パスフォーマット: avatars/<user_uuid>/avatar.jpg
-- - 読み取り: 全員許可(public-read。ペア間で互いのアバターを表示するため)
-- - 書き込み: 自分のフォルダにのみ INSERT/UPDATE/DELETE 可

-- Bucket 作成(冪等)
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = excluded.public;

-- RLS ポリシー: avatars バケット
-- 既存ポリシーがあれば置き換える
drop policy if exists "avatars_public_read" on storage.objects;
drop policy if exists "avatars_insert_own"  on storage.objects;
drop policy if exists "avatars_update_own"  on storage.objects;
drop policy if exists "avatars_delete_own"  on storage.objects;

create policy "avatars_public_read"
  on storage.objects for select
  using (bucket_id = 'avatars');

create policy "avatars_insert_own"
  on storage.objects for insert
  with check (
    bucket_id = 'avatars'
    and auth.role() = 'authenticated'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_update_own"
  on storage.objects for update
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "avatars_delete_own"
  on storage.objects for delete
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
