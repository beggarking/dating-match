-- 교만추 (교통대 소개팅) 회원 · 프로필 저장용 설정
-- Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run 하세요. (여러 번 실행해도 안전)
--
-- 보안 구조
--   - 브라우저는 테이블을 직접 읽거나 쓸 수 없음 (RLS 켜고 정책 없음 + 권한 회수)
--   - 아래 ml_* 함수만 호출 가능. 함수 안에서 로그인 토큰을 확인한다.
--   - 비밀번호는 bcrypt 해시로만 저장 (pgcrypto crypt)
--   - 다른 학생에게는 학번 · 실명을 보여주지 않고 닉네임 + 매칭용 프로필만 공개

create extension if not exists pgcrypto with schema extensions;

-- 1) 회원: 가입할 때는 학번 · 이름 · 닉네임 · 비밀번호만, 나머지는 "내 정보 수정"에서 profile 에 채운다
create table if not exists public.ml_users (
  id            uuid primary key default gen_random_uuid(),
  student_id    text not null unique check (student_id ~ '^[0-9]{7}$'),
  name          text not null check (char_length(name) between 1 and 20),
  password_hash text not null,
  profile       jsonb,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- 학번은 7자리 (이미 만든 테이블도 규칙을 갱신)
alter table public.ml_users drop constraint if exists ml_users_student_id_check;
alter table public.ml_users add constraint ml_users_student_id_check check (student_id ~ '^[0-9]{7}$');

-- 닉네임: 한글 · 영문 · 숫자 · _ 2~12자, 대소문자 구분 없이 중복 불가
alter table public.ml_users add column if not exists nickname text;
update public.ml_users set nickname = '회원' || substr(replace(id::text, '-', ''), 1, 6) where nickname is null;
alter table public.ml_users alter column nickname set not null;
alter table public.ml_users drop constraint if exists ml_users_nickname_check;
alter table public.ml_users add constraint ml_users_nickname_check check (nickname ~ '^[0-9A-Za-z가-힣_]{2,12}$');
create unique index if not exists ml_users_nickname_key on public.ml_users (lower(nickname));

-- 2) 로그인 세션: 로그인하면 토큰을 발급하고, 브라우저는 이 토큰으로 함수를 호출한다
create table if not exists public.ml_sessions (
  token      uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.ml_users(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '30 days'
);

alter table public.ml_users    enable row level security;
alter table public.ml_sessions enable row level security;
revoke all on public.ml_users, public.ml_sessions from anon, authenticated;

-- 3) 함수 ----------------------------------------------------------------------

-- 인자가 바뀐 예전 버전 정리
drop function if exists public.ml_signup(text, text, text);
drop function if exists public.ml_update_profile(uuid, text, jsonb);

-- 토큰 → 회원 id (만료됐거나 없으면 에러)
create or replace function public.ml_session_user(p_token uuid)
returns uuid language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid;
begin
  select user_id into uid from ml_sessions where token = p_token and expires_at > now();
  if uid is null then raise exception 'not_logged_in'; end if;
  return uid;
end $$;

-- 닉네임 형식 검사 + 중복 검사 (p_except: 내 닉네임을 그대로 쓰는 경우 제외할 회원 id)
create or replace function public.ml_nickname_free(p_nickname text, p_except uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_nickname is null or p_nickname !~ '^[0-9A-Za-z가-힣_]{2,12}$' then raise exception 'bad_nickname'; end if;
  return not exists (
    select 1 from ml_users where lower(nickname) = lower(p_nickname) and id is distinct from p_except
  );
end $$;

-- 회원 정보를 브라우저에 돌려줄 모양 (비밀번호 해시 제외, 본인에게만 돌려준다)
create or replace function public.ml_user_json(u public.ml_users)
returns json language sql stable set search_path = public as $$
  select json_build_object('id', u.id, 'student_id', u.student_id, 'name', u.name,
                           'nickname', u.nickname, 'profile', u.profile);
$$;

-- 닉네임 중복확인 (가입 화면의 [중복확인] 버튼)
create or replace function public.ml_check_nickname(p_nickname text)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  return json_build_object('available', ml_nickname_free(trim(p_nickname), null));
end $$;

-- 가입: 학번 · 비밀번호 · 이름 · 닉네임 → 바로 로그인된 상태로 토큰 발급
create or replace function public.ml_signup(p_student_id text, p_password text, p_name text, p_nickname text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare u ml_users; t uuid;
begin
  p_student_id := trim(p_student_id);
  p_name := trim(p_name);
  p_nickname := trim(p_nickname);
  if p_student_id !~ '^[0-9]{7}$' then raise exception 'bad_student_id'; end if;
  if char_length(p_name) not between 1 and 20 then raise exception 'bad_name'; end if;
  if char_length(p_password) < 6 then raise exception 'short_password'; end if;
  if exists (select 1 from ml_users where student_id = p_student_id) then raise exception 'already_registered'; end if;
  if not ml_nickname_free(p_nickname, null) then raise exception 'nickname_taken'; end if;

  begin
    insert into ml_users (student_id, name, nickname, password_hash)
    values (p_student_id, p_name, p_nickname, crypt(p_password, gen_salt('bf', 10)))
    returning * into u;
  exception when unique_violation then
    -- 동시에 같은 학번/닉네임으로 가입한 경우
    if exists (select 1 from ml_users where student_id = p_student_id) then raise exception 'already_registered'; end if;
    raise exception 'nickname_taken';
  end;
  insert into ml_sessions (user_id) values (u.id) returning token into t;
  return json_build_object('token', t, 'user', ml_user_json(u));
end $$;

-- 로그인: 학번 · 비밀번호 확인 → 토큰 발급
create or replace function public.ml_login(p_student_id text, p_password text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare u ml_users; t uuid;
begin
  select * into u from ml_users
  where student_id = trim(p_student_id) and password_hash = crypt(p_password, password_hash);
  if u.id is null then raise exception 'invalid_login'; end if;
  delete from ml_sessions where user_id = u.id and expires_at <= now();
  insert into ml_sessions (user_id) values (u.id) returning token into t;
  return json_build_object('token', t, 'user', ml_user_json(u));
end $$;

-- 로그아웃
create or replace function public.ml_logout(p_token uuid)
returns void language sql security definer set search_path = public as $$
  delete from ml_sessions where token = p_token;
$$;

-- 내 정보 조회
create or replace function public.ml_me(p_token uuid)
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare u ml_users;
begin
  select * into u from ml_users where id = ml_session_user(p_token);
  return ml_user_json(u);
end $$;

-- 내 정보 수정: 닉네임 + 매칭용 프로필(JSON)
create or replace function public.ml_update_profile(p_token uuid, p_nickname text, p_profile jsonb)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := ml_session_user(p_token); u ml_users;
begin
  p_nickname := trim(p_nickname);
  if not ml_nickname_free(p_nickname, uid) then raise exception 'nickname_taken'; end if;
  if jsonb_typeof(p_profile) <> 'object' or octet_length(p_profile::text) > 4000 then raise exception 'bad_profile'; end if;
  begin
    update ml_users set nickname = p_nickname, profile = p_profile, updated_at = now()
    where id = uid
    returning * into u;
  exception when unique_violation then
    raise exception 'nickname_taken';
  end;
  return ml_user_json(u);
end $$;

-- 추천 후보: 프로필을 채운 다른 회원들 (학번 · 실명은 공개하지 않고 닉네임만)
create or replace function public.ml_list_profiles(p_token uuid)
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := ml_session_user(p_token);
begin
  return coalesce((
    select json_agg(json_build_object('id', id, 'nickname', nickname, 'profile', profile) order by updated_at desc)
    from ml_users where id <> uid and profile is not null
  ), '[]'::json);
end $$;

-- 회원 탈퇴: 비밀번호 확인 후 계정과 세션 삭제
create or replace function public.ml_delete_account(p_token uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare uid uuid := ml_session_user(p_token);
begin
  if not exists (select 1 from ml_users where id = uid and password_hash = crypt(p_password, password_hash)) then
    raise exception 'invalid_login';
  end if;
  delete from ml_users where id = uid;
end $$;

-- 4) 권한: 브라우저(anon)는 아래 함수만 호출 가능 --------------------------------
revoke all on function
  public.ml_session_user(uuid), public.ml_nickname_free(text, uuid), public.ml_user_json(public.ml_users),
  public.ml_check_nickname(text), public.ml_signup(text, text, text, text), public.ml_login(text, text),
  public.ml_logout(uuid), public.ml_me(uuid), public.ml_update_profile(uuid, text, jsonb),
  public.ml_list_profiles(uuid), public.ml_delete_account(uuid, text)
from public, anon, authenticated;

grant execute on function
  public.ml_check_nickname(text), public.ml_signup(text, text, text, text), public.ml_login(text, text),
  public.ml_logout(uuid), public.ml_me(uuid), public.ml_update_profile(uuid, text, jsonb),
  public.ml_list_profiles(uuid), public.ml_delete_account(uuid, text)
to anon, authenticated;
