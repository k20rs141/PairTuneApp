-- =============================================================================
-- Migration: 0001_initial_v04.sql
-- =============================================================================
-- リポ内マイグレーション履歴の最初のスナップショット。
-- v0.4 仕様(マイルーム + ペアリング、Solo モード、履歴・アニバーサリー)の
-- 完全 schema を Supabase の SQL Editor に貼り付けて実行する想定。
--
-- 正本: docs/PairTune_DB_Schema.sql
-- 適用順: 本ファイルの Section 1 → 7 を順に実行。Section 5.8 の pg_cron は
--         本番運用直前まではコメントアウトのまま。
--
-- 既存 v0.2 schema(Beside 時代の rooms / room_participants / profiles と
-- ensure_my_room / delete_my_account RPC)はこのマイグレーションを当てる前に
-- 完全 drop することを推奨(MVP 開発中の判断、本番運用後は別マイグレーションで
-- ALTER していく)。
--
-- 冪等性 (2026-05-09 更新):
--   - 全 CREATE TABLE / INDEX / UNIQUE INDEX に IF NOT EXISTS
--   - 全 CREATE TRIGGER は事前に DROP TRIGGER IF EXISTS
--   - 全 CREATE POLICY は Section 6 冒頭で一括 DROP IF EXISTS
--   - ALTER TABLE ADD CONSTRAINT は事前に DROP CONSTRAINT IF EXISTS
--   - ALTER PUBLICATION は DO ブロックで pg_publication_tables を確認
--   - CREATE OR REPLACE FUNCTION は元から冪等
--   → このファイルは何度でも安全に再実行できる。途中でエラーが出たら、
--     原因を解決してから先頭から再実行すれば良い。
-- =============================================================================


-- =============================================================================
-- PairTune DB Schema (v0.4)
-- =============================================================================
-- For Supabase (PostgreSQL 15+)
-- Generated: 2026-05-02
-- Purpose: 2人特化の音楽同期アプリ PairTune の完全な DB スキーマ
--
-- アーキテクチャ概要:
--   Layer 1: Core            - profiles, rooms (基盤)
--   Layer 2: Pairing         - pair_relationships, pair_requests (関係性)
--   Layer 3: History         - *_play_history (記録)
--   Layer 4: Milestones      - pair_milestones (節目イベント)
--   Layer 5: Settings        - profile 拡張カラム (ユーザー設定)
--
-- 適用順:
--   1. Section 1-5 を順番に実行
--   2. Section 6 (RLS) は最後にまとめて適用
--   3. Section 7 (Triggers/Functions) は対応するテーブル作成後に適用
-- =============================================================================


-- =============================================================================
-- Section 1: Core Tables (profiles, rooms)
-- =============================================================================

-- profiles: Supabase auth.users と 1:1 で紐づくユーザー情報
CREATE TABLE IF NOT EXISTS profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  avatar_url TEXT,
  apple_user_id TEXT UNIQUE,                    -- Apple Sign In identifier
  pairing_code TEXT UNIQUE NOT NULL,            -- 6文字の英数字コード (O/0/I/1 除外)

  -- ペアリング情報 (Section 2 参照)
  active_pair_id UUID,                          -- 後で FK 制約追加
  my_room_id UUID,                              -- 後で FK 制約追加

  -- ユーザー設定 (Section 5 で拡張)
  share_play_history BOOLEAN DEFAULT FALSE,     -- マイルーム履歴を相手に見せるか
  share_favorites BOOLEAN DEFAULT TRUE,         -- お気に入りを相手に見せるか
  notify_partner_online BOOLEAN DEFAULT FALSE,  -- 相手オンライン通知 (default OFF)
  notify_milestones BOOLEAN DEFAULT TRUE,       -- 節目イベント通知

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_profiles_pairing_code ON profiles(pairing_code);
CREATE INDEX IF NOT EXISTS idx_profiles_apple_user_id ON profiles(apple_user_id);


-- rooms: マイルーム (Solo) と shared_room (ペア) の両方を管理
CREATE TABLE IF NOT EXISTS rooms (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  room_type TEXT NOT NULL DEFAULT 'my_room'
    CHECK (room_type IN ('my_room', 'shared_room')),

  -- 同期再生の現在状態 (last-write-wins)
  current_song_id TEXT,
  current_song_title TEXT,
  current_artist_name TEXT,
  current_artwork_url TEXT,
  current_song_duration_ms INTEGER,
  is_playing BOOLEAN DEFAULT FALSE,
  playback_position_ms INTEGER DEFAULT 0,
  host_timestamp_ms BIGINT,                     -- ホストの再生開始時刻 (ドリフト計算用)
  last_action_by UUID REFERENCES profiles(id),  -- 最後に操作したユーザー
  last_action_at TIMESTAMPTZ,

  -- メタデータ
  pairing_code TEXT UNIQUE,                     -- マイルーム時のみ使用 (shared_room では NULL)

  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rooms_pairing_code ON rooms(pairing_code) WHERE pairing_code IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_rooms_type ON rooms(room_type);


-- room_participants: ルーム参加者 (Presence ログ用)
CREATE TABLE IF NOT EXISTS room_participants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  left_at TIMESTAMPTZ,
  is_host BOOLEAN DEFAULT FALSE,                -- shared_room では両者 TRUE

  CONSTRAINT unique_active_participant UNIQUE (room_id, user_id, joined_at)
);

CREATE INDEX IF NOT EXISTS idx_room_participants_room_id ON room_participants(room_id);
CREATE INDEX IF NOT EXISTS idx_room_participants_user_id ON room_participants(user_id);
CREATE INDEX IF NOT EXISTS idx_room_participants_active ON room_participants(room_id, user_id) WHERE left_at IS NULL;


-- profile の FK 制約追加 (rooms 作成後)
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS fk_profiles_my_room;
ALTER TABLE profiles
  ADD CONSTRAINT fk_profiles_my_room
  FOREIGN KEY (my_room_id) REFERENCES rooms(id) ON DELETE SET NULL;


-- =============================================================================
-- Section 2: Pairing Layer (pair_relationships, pair_requests)
-- =============================================================================

-- pair_relationships: 2人の関係性
CREATE TABLE IF NOT EXISTS pair_relationships (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  user_b_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  shared_room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  paired_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  status TEXT NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'paused', 'ended')),
  ended_at TIMESTAMPTZ,
  ended_by UUID REFERENCES profiles(id),

  -- 思い出保持の設定 (解消時に決定)
  preserve_memories BOOLEAN DEFAULT TRUE,       -- false なら 90 日後完全削除
  scheduled_deletion_at TIMESTAMPTZ,            -- 完全削除予定日

  CONSTRAINT unique_pair UNIQUE (user_a_id, user_b_id),
  CONSTRAINT ordered_pair CHECK (user_a_id < user_b_id)  -- (A,B)/(B,A) 重複防止
);

-- 1ユーザー1アクティブペア (MVP制約、v1.2で緩和可能)
CREATE UNIQUE INDEX IF NOT EXISTS one_active_pair_per_user_a
  ON pair_relationships (user_a_id) WHERE status = 'active';
CREATE UNIQUE INDEX IF NOT EXISTS one_active_pair_per_user_b
  ON pair_relationships (user_b_id) WHERE status = 'active';

CREATE INDEX IF NOT EXISTS idx_pair_relationships_status ON pair_relationships(status);
CREATE INDEX IF NOT EXISTS idx_pair_relationships_users ON pair_relationships(user_a_id, user_b_id);
CREATE INDEX IF NOT EXISTS idx_pair_relationships_scheduled_deletion
  ON pair_relationships(scheduled_deletion_at) WHERE scheduled_deletion_at IS NOT NULL;


-- profiles.active_pair_id の FK 制約追加
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS fk_profiles_active_pair;
ALTER TABLE profiles
  ADD CONSTRAINT fk_profiles_active_pair
  FOREIGN KEY (active_pair_id) REFERENCES pair_relationships(id) ON DELETE SET NULL;


-- pair_requests: ペアリング申請 (24時間で自動失効)
CREATE TABLE IF NOT EXISTS pair_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  target_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'accepted', 'rejected', 'expired')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  responded_at TIMESTAMPTZ,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '24 hours',

  CONSTRAINT no_self_request CHECK (requester_id != target_id)
);

-- 同じ相手への重複申請を防ぐ (pending のみ)
CREATE UNIQUE INDEX IF NOT EXISTS no_duplicate_pending_request
  ON pair_requests (requester_id, target_id) WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_pair_requests_target_pending
  ON pair_requests(target_id) WHERE status = 'pending';
CREATE INDEX IF NOT EXISTS idx_pair_requests_expires_at
  ON pair_requests(expires_at) WHERE status = 'pending';


-- =============================================================================
-- Section 3: History Layer (再生履歴)
-- =============================================================================

-- shared_room_play_history: ふたりで聴いた履歴 (アニバーサリー機能の根幹)
CREATE TABLE IF NOT EXISTS shared_room_play_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shared_room_id UUID NOT NULL REFERENCES rooms(id) ON DELETE CASCADE,
  pair_id UUID NOT NULL REFERENCES pair_relationships(id) ON DELETE CASCADE,

  -- 曲情報 (Apple Music)
  song_id TEXT NOT NULL,
  song_title TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  album_title TEXT,
  artwork_url TEXT,

  -- 再生情報
  played_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  played_duration_seconds INTEGER NOT NULL,     -- 30秒未満は INSERT しない (アプリ層で制御)
  total_duration_seconds INTEGER,               -- 曲の長さ
  initiated_by UUID REFERENCES profiles(id),    -- どちらが選曲したか

  -- アニバーサリー機能用フラグ
  is_first_play BOOLEAN DEFAULT FALSE,          -- このペアで初めて聴いた曲か (トリガで自動設定)
  session_id UUID                               -- 同一セッションのグルーピング (アプリ層で生成)
);

CREATE INDEX IF NOT EXISTS idx_shared_history_pair_id ON shared_room_play_history(pair_id);
CREATE INDEX IF NOT EXISTS idx_shared_history_played_at ON shared_room_play_history(played_at DESC);
CREATE INDEX IF NOT EXISTS idx_shared_history_pair_song ON shared_room_play_history(pair_id, song_id);
CREATE INDEX IF NOT EXISTS idx_shared_history_first_play
  ON shared_room_play_history(pair_id, is_first_play) WHERE is_first_play = TRUE;

-- 「1年前の今日」クエリの効率化用
CREATE INDEX IF NOT EXISTS idx_shared_history_anniversary
  ON shared_room_play_history(pair_id, played_at);


-- my_room_play_history: 個人のマイルーム履歴 (Solo モード用)
CREATE TABLE IF NOT EXISTS my_room_play_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,

  -- 曲情報
  song_id TEXT NOT NULL,
  song_title TEXT NOT NULL,
  artist_name TEXT NOT NULL,
  album_title TEXT,
  artwork_url TEXT,

  -- 再生情報
  played_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  played_duration_seconds INTEGER NOT NULL,

  -- お気に入り (相手に共有可能)
  is_favorited BOOLEAN DEFAULT FALSE,
  favorited_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_my_history_user_id ON my_room_play_history(user_id);
CREATE INDEX IF NOT EXISTS idx_my_history_played_at ON my_room_play_history(played_at DESC);
CREATE INDEX IF NOT EXISTS idx_my_history_favorites
  ON my_room_play_history(user_id, is_favorited) WHERE is_favorited = TRUE;


-- =============================================================================
-- Section 4: Milestones (節目イベント、v1.2 で UI 化)
-- =============================================================================

-- pair_milestones: 自動検出された節目イベント
CREATE TABLE IF NOT EXISTS pair_milestones (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pair_id UUID NOT NULL REFERENCES pair_relationships(id) ON DELETE CASCADE,
  milestone_type TEXT NOT NULL,
  -- type 例: 'anniversary_30d', 'anniversary_100d', 'anniversary_1y',
  --        'songs_100', 'songs_1000', 'duration_24h', 'streak_7d'

  achieved_at TIMESTAMPTZ NOT NULL,
  metadata JSONB,                               -- 例: {"song_count": 100, "first_song_id": "..."}
  notified_at TIMESTAMPTZ,
  acknowledged_at TIMESTAMPTZ,                  -- ユーザーが見た時刻

  CONSTRAINT unique_milestone_per_pair UNIQUE (pair_id, milestone_type)
);

CREATE INDEX IF NOT EXISTS idx_milestones_pair_id ON pair_milestones(pair_id);
CREATE INDEX IF NOT EXISTS idx_milestones_unnotified
  ON pair_milestones(pair_id) WHERE notified_at IS NULL;


-- =============================================================================
-- Section 5: Triggers and Functions
-- =============================================================================

-- 5.1: ユーザー作成時にマイルームを自動生成
-- ⚠️ SECURITY DEFINER 関数は明示的に search_path を設定すること。
--     auth.users の INSERT は supabase_auth_admin ロールから来るため、
--     search_path に public が含まれていないと profiles / rooms を見つけられず
--     "Database error saving new user" 500 エラーになる。
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  new_room_id UUID;
  new_pairing_code TEXT;
BEGIN
  -- ユニークなペアリングコード生成 (6文字、O/0/I/1 除外)
  -- profiles と rooms の両方で UNIQUE 制約があるため両方をチェックする。
  LOOP
    new_pairing_code := upper(
      substring(md5(random()::text || clock_timestamp()::text)
        FROM 1 FOR 8)
    );
    -- 紛らわしい文字を除去
    new_pairing_code := translate(new_pairing_code, 'O0I1', '');
    new_pairing_code := substring(new_pairing_code FROM 1 FOR 6);

    EXIT WHEN length(new_pairing_code) = 6
      AND NOT EXISTS (SELECT 1 FROM profiles WHERE pairing_code = new_pairing_code)
      AND NOT EXISTS (SELECT 1 FROM rooms WHERE pairing_code = new_pairing_code);
  END LOOP;

  -- マイルーム作成
  INSERT INTO rooms (room_type, pairing_code)
  VALUES ('my_room', new_pairing_code)
  RETURNING id INTO new_room_id;

  -- profile 作成
  INSERT INTO profiles (id, display_name, apple_user_id, pairing_code, my_room_id)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'display_name', 'User'),
    NEW.raw_user_meta_data->>'apple_user_id',
    new_pairing_code,
    new_room_id
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- 5.2: ペアリング承認時に shared_room を生成し関係を確立
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

  RETURN v_pair_id;
END;
$$;


-- 5.3: ペアリング解消
CREATE OR REPLACE FUNCTION end_pair_relationship(
  p_pair_id UUID,
  p_ended_by UUID,
  p_preserve_memories BOOLEAN DEFAULT TRUE
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_user_a UUID;
  v_user_b UUID;
BEGIN
  SELECT user_a_id, user_b_id INTO v_user_a, v_user_b
  FROM pair_relationships WHERE id = p_pair_id;

  -- pair_relationships を ended に
  UPDATE pair_relationships
  SET status = 'ended',
      ended_at = NOW(),
      ended_by = p_ended_by,
      preserve_memories = p_preserve_memories,
      scheduled_deletion_at = CASE
        WHEN p_preserve_memories THEN NULL
        ELSE NOW() + INTERVAL '90 days'
      END
  WHERE id = p_pair_id;

  -- 両者の active_pair_id を NULL に
  UPDATE profiles SET active_pair_id = NULL
  WHERE id IN (v_user_a, v_user_b);
END;
$$;


-- 5.4: 「初めて聴いた曲」自動マーキング
CREATE OR REPLACE FUNCTION mark_first_play()
RETURNS TRIGGER AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM shared_room_play_history
    WHERE pair_id = NEW.pair_id
      AND song_id = NEW.song_id
      AND id != NEW.id
  ) THEN
    NEW.is_first_play := TRUE;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS set_first_play ON shared_room_play_history;
CREATE TRIGGER set_first_play
  BEFORE INSERT ON shared_room_play_history
  FOR EACH ROW EXECUTE FUNCTION mark_first_play();


-- 5.5: 期限切れ pair_requests を自動更新 (pg_cron で日次実行)
CREATE OR REPLACE FUNCTION expire_old_pair_requests()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  UPDATE pair_requests
  SET status = 'expired', responded_at = NOW()
  WHERE status = 'pending' AND expires_at < NOW();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


-- 5.6: 90日経過した解消ペアの完全削除 (pg_cron で日次実行)
CREATE OR REPLACE FUNCTION cleanup_ended_pairs()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count INTEGER;
BEGIN
  DELETE FROM pair_relationships
  WHERE status = 'ended'
    AND scheduled_deletion_at IS NOT NULL
    AND scheduled_deletion_at < NOW();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;


-- 5.7: 節目イベント検出 (pg_cron で日次実行、v1.2 で UI 化)
CREATE OR REPLACE FUNCTION detect_milestones()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_count INTEGER := 0;
  v_pair RECORD;
BEGIN
  -- ペアリング 30日記念
  FOR v_pair IN
    SELECT id, paired_at FROM pair_relationships
    WHERE status = 'active'
      AND paired_at <= NOW() - INTERVAL '30 days'
      AND NOT EXISTS (
        SELECT 1 FROM pair_milestones
        WHERE pair_id = pair_relationships.id
          AND milestone_type = 'anniversary_30d'
      )
  LOOP
    INSERT INTO pair_milestones (pair_id, milestone_type, achieved_at)
    VALUES (v_pair.id, 'anniversary_30d', v_pair.paired_at + INTERVAL '30 days');
    v_count := v_count + 1;
  END LOOP;

  -- ペアリング 100日記念
  FOR v_pair IN
    SELECT id, paired_at FROM pair_relationships
    WHERE status = 'active'
      AND paired_at <= NOW() - INTERVAL '100 days'
      AND NOT EXISTS (
        SELECT 1 FROM pair_milestones
        WHERE pair_id = pair_relationships.id
          AND milestone_type = 'anniversary_100d'
      )
  LOOP
    INSERT INTO pair_milestones (pair_id, milestone_type, achieved_at)
    VALUES (v_pair.id, 'anniversary_100d', v_pair.paired_at + INTERVAL '100 days');
    v_count := v_count + 1;
  END LOOP;

  -- ペアリング 1年記念
  FOR v_pair IN
    SELECT id, paired_at FROM pair_relationships
    WHERE status = 'active'
      AND paired_at <= NOW() - INTERVAL '365 days'
      AND NOT EXISTS (
        SELECT 1 FROM pair_milestones
        WHERE pair_id = pair_relationships.id
          AND milestone_type = 'anniversary_1y'
      )
  LOOP
    INSERT INTO pair_milestones (pair_id, milestone_type, achieved_at)
    VALUES (v_pair.id, 'anniversary_1y', v_pair.paired_at + INTERVAL '365 days');
    v_count := v_count + 1;
  END LOOP;

  -- TODO: songs_100, songs_1000, duration_24h, streak_7d 等を追加
  -- これらは集計クエリが重いので別バッチで処理することを推奨

  RETURN v_count;
END;
$$;


-- 5.8: pg_cron スケジューリング (Supabase ダッシュボードで設定)
-- 以下を Supabase の SQL Editor または pg_cron 拡張経由で実行
/*
SELECT cron.schedule(
  'expire-pair-requests',
  '0 * * * *',  -- 毎時
  'SELECT expire_old_pair_requests();'
);

SELECT cron.schedule(
  'cleanup-ended-pairs',
  '0 3 * * *',  -- 毎日 3時
  'SELECT cleanup_ended_pairs();'
);

SELECT cron.schedule(
  'detect-milestones',
  '0 6 * * *',  -- 毎日 6時 (朝の通知に間に合わせる)
  'SELECT detect_milestones();'
);
*/


-- =============================================================================
-- Section 6: Row Level Security (RLS) Policies
-- =============================================================================

-- 全テーブルで RLS 有効化
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE rooms ENABLE ROW LEVEL SECURITY;
ALTER TABLE room_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE pair_relationships ENABLE ROW LEVEL SECURITY;
ALTER TABLE pair_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE shared_room_play_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE my_room_play_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE pair_milestones ENABLE ROW LEVEL SECURITY;


-- 冪等性のため、既存ポリシーを一旦すべて drop してから再作成する。
-- (Postgres には CREATE OR REPLACE POLICY が無いため、DROP + CREATE で対応)
DROP POLICY IF EXISTS "Users can view own profile" ON profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON profiles;
DROP POLICY IF EXISTS "Users can view paired partner profile" ON profiles;
DROP POLICY IF EXISTS "Target can view requester profile" ON profiles;

DROP POLICY IF EXISTS "Users can access own my_room" ON rooms;
DROP POLICY IF EXISTS "Pair members can access shared room" ON rooms;
DROP POLICY IF EXISTS "Anyone can lookup room by code for joining" ON rooms;

DROP POLICY IF EXISTS "Users can view participants of accessible rooms" ON room_participants;
DROP POLICY IF EXISTS "Users can manage own participation" ON room_participants;

DROP POLICY IF EXISTS "Users can view own pair relationships" ON pair_relationships;

DROP POLICY IF EXISTS "Users can view their pair requests" ON pair_requests;
DROP POLICY IF EXISTS "Users can create pair requests as requester" ON pair_requests;
DROP POLICY IF EXISTS "Target can update pair requests" ON pair_requests;

DROP POLICY IF EXISTS "Pair members can view shared history" ON shared_room_play_history;
DROP POLICY IF EXISTS "Pair members can insert shared history" ON shared_room_play_history;

DROP POLICY IF EXISTS "Users can view own history" ON my_room_play_history;
DROP POLICY IF EXISTS "Partner can view shared history" ON my_room_play_history;
DROP POLICY IF EXISTS "Partner can view shared favorites" ON my_room_play_history;
DROP POLICY IF EXISTS "Users can insert own history" ON my_room_play_history;
DROP POLICY IF EXISTS "Users can update own history" ON my_room_play_history;
DROP POLICY IF EXISTS "Users can delete own history" ON my_room_play_history;

DROP POLICY IF EXISTS "Pair members can view milestones" ON pair_milestones;
DROP POLICY IF EXISTS "Pair members can update acknowledged_at" ON pair_milestones;


-- 6.1: profiles のポリシー
-- 自分のプロフィールは閲覧・更新可能
CREATE POLICY "Users can view own profile"
  ON profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON profiles FOR UPDATE
  USING (auth.uid() = id);

-- ペアリング相手のプロフィールは閲覧可能
CREATE POLICY "Users can view paired partner profile"
  ON profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pair_relationships
      WHERE status = 'active'
        AND ((user_a_id = auth.uid() AND user_b_id = profiles.id)
          OR (user_b_id = auth.uid() AND user_a_id = profiles.id))
    )
  );

-- ペアリング申請のターゲット側は requester のプロフィールを閲覧可能 (申請モーダル表示用)
CREATE POLICY "Target can view requester profile"
  ON profiles FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pair_requests
      WHERE status = 'pending'
        AND target_id = auth.uid()
        AND requester_id = profiles.id
    )
  );


-- 6.2: rooms のポリシー
-- マイルーム: 自分のもののみアクセス可
CREATE POLICY "Users can access own my_room"
  ON rooms FOR ALL
  USING (
    room_type = 'my_room' AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND my_room_id = rooms.id)
  );

-- shared_room: ペア当事者のみアクセス可
CREATE POLICY "Pair members can access shared room"
  ON rooms FOR ALL
  USING (
    room_type = 'shared_room' AND
    EXISTS (
      SELECT 1 FROM pair_relationships
      WHERE shared_room_id = rooms.id
        AND status = 'active'
        AND (user_a_id = auth.uid() OR user_b_id = auth.uid())
    )
  );

-- コードによるマイルーム参照 (Guest モード用、SELECT のみ)
CREATE POLICY "Anyone can lookup room by code for joining"
  ON rooms FOR SELECT
  USING (
    room_type = 'my_room' AND
    pairing_code IS NOT NULL
  );


-- 6.3: room_participants のポリシー
CREATE POLICY "Users can view participants of accessible rooms"
  ON room_participants FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM rooms
      WHERE rooms.id = room_participants.room_id
      -- rooms の RLS で既にフィルタ済み
    )
  );

CREATE POLICY "Users can manage own participation"
  ON room_participants FOR ALL
  USING (auth.uid() = user_id);


-- 6.4: pair_relationships のポリシー
CREATE POLICY "Users can view own pair relationships"
  ON pair_relationships FOR SELECT
  USING (auth.uid() = user_a_id OR auth.uid() = user_b_id);

-- INSERT は accept_pair_request() 経由のみ (SECURITY DEFINER)
-- UPDATE は end_pair_relationship() 経由のみ (SECURITY DEFINER)


-- 6.5: pair_requests のポリシー
CREATE POLICY "Users can view their pair requests"
  ON pair_requests FOR SELECT
  USING (auth.uid() = requester_id OR auth.uid() = target_id);

CREATE POLICY "Users can create pair requests as requester"
  ON pair_requests FOR INSERT
  WITH CHECK (auth.uid() = requester_id);

CREATE POLICY "Target can update pair requests"
  ON pair_requests FOR UPDATE
  USING (auth.uid() = target_id);


-- 6.6: shared_room_play_history のポリシー
CREATE POLICY "Pair members can view shared history"
  ON shared_room_play_history FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pair_relationships
      WHERE id = shared_room_play_history.pair_id
        AND (status = 'active' OR (status = 'ended' AND preserve_memories = TRUE))
        AND (user_a_id = auth.uid() OR user_b_id = auth.uid())
    )
  );

CREATE POLICY "Pair members can insert shared history"
  ON shared_room_play_history FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM pair_relationships
      WHERE id = shared_room_play_history.pair_id
        AND status = 'active'
        AND (user_a_id = auth.uid() OR user_b_id = auth.uid())
    )
  );


-- 6.7: my_room_play_history のポリシー
CREATE POLICY "Users can view own history"
  ON my_room_play_history FOR SELECT
  USING (auth.uid() = user_id);

-- 相手の履歴は share_play_history が ON のときのみ閲覧可
CREATE POLICY "Partner can view shared history"
  ON my_room_play_history FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pair_relationships pr
      JOIN profiles p ON p.id = my_room_play_history.user_id
      WHERE p.share_play_history = TRUE
        AND pr.status = 'active'
        AND (
          (pr.user_a_id = my_room_play_history.user_id AND pr.user_b_id = auth.uid()) OR
          (pr.user_b_id = my_room_play_history.user_id AND pr.user_a_id = auth.uid())
        )
    )
  );

-- お気に入りは share_favorites が ON のときのみ閲覧可
CREATE POLICY "Partner can view shared favorites"
  ON my_room_play_history FOR SELECT
  USING (
    is_favorited = TRUE AND
    EXISTS (
      SELECT 1 FROM pair_relationships pr
      JOIN profiles p ON p.id = my_room_play_history.user_id
      WHERE p.share_favorites = TRUE
        AND pr.status = 'active'
        AND (
          (pr.user_a_id = my_room_play_history.user_id AND pr.user_b_id = auth.uid()) OR
          (pr.user_b_id = my_room_play_history.user_id AND pr.user_a_id = auth.uid())
        )
    )
  );

CREATE POLICY "Users can insert own history"
  ON my_room_play_history FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own history"
  ON my_room_play_history FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own history"
  ON my_room_play_history FOR DELETE
  USING (auth.uid() = user_id);


-- 6.8: pair_milestones のポリシー
CREATE POLICY "Pair members can view milestones"
  ON pair_milestones FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM pair_relationships
      WHERE id = pair_milestones.pair_id
        AND (user_a_id = auth.uid() OR user_b_id = auth.uid())
    )
  );

CREATE POLICY "Pair members can update acknowledged_at"
  ON pair_milestones FOR UPDATE
  USING (
    EXISTS (
      SELECT 1 FROM pair_relationships
      WHERE id = pair_milestones.pair_id
        AND status = 'active'
        AND (user_a_id = auth.uid() OR user_b_id = auth.uid())
    )
  );


-- =============================================================================
-- Section 7: Realtime Configuration
-- =============================================================================

-- Supabase Realtime: 必要なテーブルのみ有効化
-- ALTER PUBLICATION ADD TABLE は重複時にエラーになるため、
-- pg_publication_tables で既存登録をチェックしてから追加する。
DO $$
DECLARE
  t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['rooms', 'room_participants', 'pair_requests',
                           'pair_relationships', 'pair_milestones']
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
       WHERE pubname = 'supabase_realtime' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE %I', t);
    END IF;
  END LOOP;
END $$;

-- shared_room_play_history と my_room_play_history は Realtime 不要
-- (集計クエリのみ、新規INSERT は単発で送信される)


-- =============================================================================
-- Section 8: Indexes for Performance
-- =============================================================================

-- 上記の各テーブル定義内で既に最適なインデックスを設定済み
-- 必要に応じて以下を追加可能:

-- 履歴の集計クエリ用 (アニバーサリー機能で使用)
CREATE INDEX IF NOT EXISTS idx_shared_history_pair_played_at
  ON shared_room_play_history(pair_id, played_at DESC);

-- ペアリング検索用
CREATE INDEX IF NOT EXISTS idx_profiles_active_pair
  ON profiles(active_pair_id) WHERE active_pair_id IS NOT NULL;


-- =============================================================================
-- Section 9: Sample Queries (参考用)
-- =============================================================================

/*
-- 9.1: あるペアの「ふたりで聴いた曲」直近10件
SELECT song_id, song_title, artist_name, artwork_url, played_at, is_first_play
FROM shared_room_play_history
WHERE pair_id = $1
ORDER BY played_at DESC
LIMIT 10;

-- 9.2: 「1年前の今日」聴いた曲
SELECT *
FROM shared_room_play_history
WHERE pair_id = $1
  AND played_at >= NOW() - INTERVAL '365 days 12 hours'
  AND played_at < NOW() - INTERVAL '364 days 12 hours'
ORDER BY played_at DESC;

-- 9.3: あるペアの累計再生時間 (秒)
SELECT SUM(played_duration_seconds)
FROM shared_room_play_history
WHERE pair_id = $1;

-- 9.4: 「ふたりで聴いた曲ランキング」 (再生回数で集計)
SELECT
  song_id,
  song_title,
  artist_name,
  artwork_url,
  COUNT(*) as play_count,
  SUM(played_duration_seconds) as total_duration_seconds
FROM shared_room_play_history
WHERE pair_id = $1
GROUP BY song_id, song_title, artist_name, artwork_url
ORDER BY play_count DESC, total_duration_seconds DESC
LIMIT 10;

-- 9.5: 相手の最近のお気に入り (Solo モードで表示)
SELECT mh.*
FROM my_room_play_history mh
JOIN profiles p ON p.id = mh.user_id
JOIN pair_relationships pr ON
  (pr.user_a_id = mh.user_id AND pr.user_b_id = $1) OR
  (pr.user_b_id = mh.user_id AND pr.user_a_id = $1)
WHERE pr.status = 'active'
  AND p.share_favorites = TRUE
  AND mh.is_favorited = TRUE
ORDER BY mh.favorited_at DESC
LIMIT 5;

-- 9.6: 未通知の節目イベントを取得 (バッチ処理用)
SELECT m.*, pr.user_a_id, pr.user_b_id
FROM pair_milestones m
JOIN pair_relationships pr ON pr.id = m.pair_id
WHERE m.notified_at IS NULL
  AND pr.status = 'active'
ORDER BY m.achieved_at;
*/


-- =============================================================================
-- End of PairTune DB Schema v0.4
-- =============================================================================
