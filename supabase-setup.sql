-- Match Lab (교통대 소개팅) 회원 · 프로필 저장용 설정
-- Supabase 대시보드 > SQL Editor 에 전체 붙여넣고 Run 하세요. (여러 번 실행해도 안전)
--
-- 보안 구조
--   - 브라우저는 테이블을 직접 읽거나 쓸 수 없음 (RLS 켜고 정책 없음 + 권한 회수)
--   - 아래 ml_* 함수만 호출 가능. 함수 안에서 로그인 토큰을 확인한다.
--   - 비밀번호는 bcrypt 해시로만 저장 (pgcrypto crypt)
--   - 다른 학생에게는 학번을 보여주지 않고 이름 + 매칭용 프로필만 공개

create extension if not exists pgcrypto with schema extensions;

-- 1) 회원: 가입할 때는 학번 · 이름 · 비밀번호만, 나머지는 "내 정보 수정"에서 profile 에 채운다
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

-- 토큰 → 회원 id (만료됐거나 없으면 에러)
create or replace function public.ml_session_user(p_token uuid)
returns uuid language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid;
begin
  select user_id into uid from ml_sessions where token = p_token and expires_at > now();
  if uid is null then raise exception 'not_logged_in'; end if;
  return uid;
end $$;

-- 회원 정보를 브라우저에 돌려줄 모양 (비밀번호 해시 제외)
create or replace function public.ml_user_json(u public.ml_users)
returns json language sql stable set search_path = public as $$
  select json_build_object('id', u.id, 'student_id', u.student_id, 'name', u.name, 'profile', u.profile);
$$;

-- 가입: 학번 · 비밀번호 · 이름 → 바로 로그인된 상태로 토큰 발급
create or replace function public.ml_signup(p_student_id text, p_password text, p_name text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare u ml_users; t uuid;
begin
  p_student_id := trim(p_student_id);
  p_name := trim(p_name);
  if p_student_id !~ '^[0-9]{7}$' then raise exception 'bad_student_id'; end if;
  if char_length(p_name) not between 1 and 20 then raise exception 'bad_name'; end if;
  if char_length(p_password) < 6 then raise exception 'short_password'; end if;
  if exists (select 1 from ml_users where student_id = p_student_id) then raise exception 'already_registered'; end if;

  insert into ml_users (student_id, name, password_hash)
  values (p_student_id, p_name, crypt(p_password, gen_salt('bf', 10)))
  returning * into u;
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

-- 내 정보 수정: 이름 + 매칭용 프로필(JSON)
create or replace function public.ml_update_profile(p_token uuid, p_name text, p_profile jsonb)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare u ml_users;
begin
  p_name := trim(p_name);
  if char_length(p_name) not between 1 and 20 then raise exception 'bad_name'; end if;
  if jsonb_typeof(p_profile) <> 'object' or octet_length(p_profile::text) > 4000 then raise exception 'bad_profile'; end if;
  update ml_users set name = p_name, profile = p_profile, updated_at = now()
  where id = ml_session_user(p_token)
  returning * into u;
  return ml_user_json(u);
end $$;

-- 추천 후보: 프로필을 채운 다른 회원들 (학번은 공개하지 않음)
create or replace function public.ml_list_profiles(p_token uuid)
returns json language plpgsql stable security definer set search_path = public, extensions as $$
declare uid uuid := ml_session_user(p_token);
begin
  return coalesce((
    select json_agg(json_build_object('id', id, 'name', name, 'profile', profile) order by updated_at desc)
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
  public.ml_session_user(uuid), public.ml_user_json(public.ml_users),
  public.ml_signup(text, text, text), public.ml_login(text, text), public.ml_logout(uuid),
  public.ml_me(uuid), public.ml_update_profile(uuid, text, jsonb),
  public.ml_list_profiles(uuid), public.ml_delete_account(uuid, text)
from public, anon, authenticated;

grant execute on function
  public.ml_signup(text, text, text), public.ml_login(text, text), public.ml_logout(uuid),
  public.ml_me(uuid), public.ml_update_profile(uuid, text, jsonb),
  public.ml_list_profiles(uuid), public.ml_delete_account(uuid, text)
to anon, authenticated;
