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

-- 3) 오늘의 추천 기록 (하루 5번), 별점, 대화 요청
--    target: 가상 프로필은 'v-이름', 회원은 회원 id(uuid 문자열)
create table if not exists public.ml_draws (
  user_id    uuid not null references public.ml_users(id) on delete cascade,
  day        date not null default (now() at time zone 'Asia/Seoul')::date,
  target     text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, day, target)
);
create table if not exists public.ml_ratings (
  rater_id   uuid not null references public.ml_users(id) on delete cascade,
  target     text not null,
  stars      smallint not null check (stars between 1 and 5),
  updated_at timestamptz not null default now(),
  primary key (rater_id, target)
);
create table if not exists public.ml_chat_requests (
  from_id    uuid not null references public.ml_users(id) on delete cascade,
  target     text not null,
  created_at timestamptz not null default now(),
  primary key (from_id, target)
);

-- 커뮤니티: 글 + 댓글. 글쓴이는 회원(author_id) 이거나, 처음 화면이 비지 않게 넣어 둔 가상 프로필(author_v)
create table if not exists public.ml_posts (
  id         bigint generated always as identity primary key,
  author_id  uuid references public.ml_users(id) on delete cascade,
  author_v   text,
  body       text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now(),
  check ((author_id is null) <> (author_v is null))
);
create table if not exists public.ml_comments (
  id         bigint generated always as identity primary key,
  post_id    bigint not null references public.ml_posts(id) on delete cascade,
  author_id  uuid not null references public.ml_users(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 300),
  created_at timestamptz not null default now()
);
create index if not exists ml_comments_post on public.ml_comments (post_id, created_at);

insert into public.ml_posts (author_v, body, created_at)
select v.a, v.b, now() - make_interval(hours => v.h)
from (values
  ('v-하린', '이번 주 축제 같이 갈 사람 있나요? 라인업이 역대급이래요!', 2),
  ('v-준호', '영화 동아리 이번 주 금요일 상영작은 이터널 선샤인이에요. 동아리 아니어도 누구나 와도 돼요.', 5),
  ('v-예린', '오늘 도서관 앞에서 학교 고양이 치즈 봤어요. 햇볕 쬐면서 자는데 너무 귀여웠어요', 9),
  ('v-도윤', '학교 앞에 새로 생긴 국밥집 가봤는데 양이 진짜 많아요. 시험기간에 강추합니다', 20),
  ('v-다은', '중간고사 끝나면 혼자 영화관 가는 게 제 루틴인데, 다들 시험 끝나고 뭐 하세요?', 30),
  ('v-태민', '방학에 양양으로 서핑 같이 갈 사람 구해요. 처음 타는 사람도 환영!', 44)
) as v(a, b, h)
where not exists (select 1 from public.ml_posts p where p.author_v = v.a and p.body = v.b);

alter table public.ml_users         enable row level security;
alter table public.ml_sessions      enable row level security;
alter table public.ml_draws         enable row level security;
alter table public.ml_ratings       enable row level security;
alter table public.ml_chat_requests enable row level security;
alter table public.ml_posts         enable row level security;
alter table public.ml_comments      enable row level security;
revoke all on public.ml_users, public.ml_sessions, public.ml_draws, public.ml_ratings, public.ml_chat_requests,
              public.ml_posts, public.ml_comments from anon, authenticated;

-- 4) 함수 ----------------------------------------------------------------------

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
  -- 사진(photo)은 브라우저에서 작게 줄인 JPEG data URL, 나머지 정보는 4000바이트 이하
  if jsonb_typeof(p_profile) <> 'object' or octet_length((p_profile - 'photo')::text) > 4000
     or (p_profile->>'photo') !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$'
     or octet_length(p_profile->>'photo') > 140000 then
    raise exception 'bad_profile';
  end if;
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
  -- 내가 남긴 기록은 외래키로 같이 지워지고, 나를 대상으로 한 기록은 여기서 지운다
  delete from ml_draws where target = uid::text;
  delete from ml_ratings where target = uid::text;
  delete from ml_chat_requests where target = uid::text;
  delete from ml_users where id = uid;
end $$;

-- 추천 · 평가 대상 확인: 가상 프로필 id 이거나, 프로필을 채운 다른 회원
create or replace function public.ml_check_target(uid uuid, p_target text)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if p_target ~ '^v-[가-힣]{1,10}$' then return; end if;
  if p_target ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and p_target <> uid::text
     and exists (select 1 from ml_users where id = p_target::uuid and profile is not null) then
    return;
  end if;
  raise exception 'bad_target';
end $$;

-- 오늘의 추천 · 별점 · 대화 요청 화면에 필요한 정보 한 묶음
--   ratings: 모든 사람의 평균 별점 (인기 랭킹, 내 평점에 사용)
create or replace function public.ml_home_json(uid uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'limit', 5,
    'today', coalesce((select json_agg(target order by created_at) from ml_draws
                       where user_id = uid and day = (now() at time zone 'Asia/Seoul')::date), '[]'::json),
    'given', coalesce((select json_object_agg(target, stars) from ml_ratings where rater_id = uid), '{}'::json),
    'sent', coalesce((select json_agg(target) from ml_chat_requests where from_id = uid), '[]'::json),
    'received', coalesce((select json_agg(json_build_object('id', u.id, 'nickname', u.nickname, 'at', c.created_at) order by c.created_at desc)
                          from ml_chat_requests c join ml_users u on u.id = c.from_id
                          where c.target = uid::text), '[]'::json),
    'ratings', coalesce((select json_object_agg(target, json_build_object('avg', round(a, 2), 'count', n))
                         from (select target, avg(stars) a, count(*) n from ml_ratings group by target) t), '{}'::json)
  );
$$;

create or replace function public.ml_home(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  return ml_home_json(ml_session_user(p_token));
end $$;

-- 오늘의 추천 받기: 하루(한국 시간) 5번까지
create or replace function public.ml_draw(p_token uuid, p_target text)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := ml_session_user(p_token); today date := (now() at time zone 'Asia/Seoul')::date;
begin
  perform ml_check_target(uid, p_target);
  perform 1 from ml_users where id = uid for update; -- 동시에 여러 번 눌러도 5번을 넘지 않게
  if (select count(*) from ml_draws where user_id = uid and day = today) >= 5 then raise exception 'daily_limit'; end if;
  insert into ml_draws (user_id, day, target) values (uid, today, p_target) on conflict do nothing;
  return ml_home_json(uid);
end $$;

-- 별점 주기 (1~5, 다시 주면 바뀜): 오늘의 추천에서 받은 사람만
create or replace function public.ml_rate(p_token uuid, p_target text, p_stars int)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := ml_session_user(p_token);
begin
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'bad_stars'; end if;
  if not exists (select 1 from ml_draws where user_id = uid and target = p_target) then raise exception 'not_recommended'; end if;
  insert into ml_ratings (rater_id, target, stars) values (uid, p_target, p_stars)
  on conflict (rater_id, target) do update set stars = excluded.stars, updated_at = now();
  return ml_home_json(uid);
end $$;

-- 대화 요청: 오늘의 추천에서 받은 사람, 또는 커뮤니티 글 · 댓글을 쓴 사람(가상 프로필 · 다른 회원)
create or replace function public.ml_chat_request(p_token uuid, p_target text)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := ml_session_user(p_token);
begin
  if not (p_target ~ '^v-[가-힣]{1,10}$'
          or (p_target ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' and p_target <> uid::text
              and exists (select 1 from ml_users where id = p_target::uuid))) then
    raise exception 'bad_target';
  end if;
  insert into ml_chat_requests (from_id, target) values (uid, p_target) on conflict do nothing;
  return ml_home_json(uid);
end $$;

-- 커뮤니티 ---------------------------------------------------------------------
-- author: 회원 id 또는 'v-이름' / nickname: 회원 닉네임 (가상 프로필은 브라우저가 이름을 붙인다)
create or replace function public.ml_feed_json(uid uuid)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(x order by x.at desc), '[]'::json) from (
    select p.id, coalesce(p.author_id::text, p.author_v) as author, u.nickname, p.body, p.created_at as at,
           p.author_id = uid as mine, (select count(*) from ml_comments c where c.post_id = p.id) as comments
    from ml_posts p left join ml_users u on u.id = p.author_id
    order by p.created_at desc limit 50
  ) x;
$$;

create or replace function public.ml_post_json(uid uuid, p_id bigint)
returns json language plpgsql stable security definer set search_path = public as $$
declare r json;
begin
  select json_build_object(
    'id', p.id, 'author', coalesce(p.author_id::text, p.author_v), 'nickname', u.nickname, 'body', p.body,
    'at', p.created_at, 'mine', p.author_id = uid,
    'comments', coalesce((select json_agg(json_build_object('id', c.id, 'author', c.author_id, 'nickname', cu.nickname,
                                                            'body', c.body, 'at', c.created_at, 'mine', c.author_id = uid)
                                          order by c.created_at)
                          from ml_comments c join ml_users cu on cu.id = c.author_id where c.post_id = p.id), '[]'::json))
  into r
  from ml_posts p left join ml_users u on u.id = p.author_id where p.id = p_id;
  if r is null then raise exception 'post_not_found'; end if;
  return r;
end $$;

create or replace function public.ml_feed(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  return ml_feed_json(ml_session_user(p_token));
end $$;

create or replace function public.ml_post(p_token uuid, p_id bigint)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  return ml_post_json(ml_session_user(p_token), p_id);
end $$;

create or replace function public.ml_write_post(p_token uuid, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := ml_session_user(p_token);
begin
  p_body := trim(p_body);
  if char_length(coalesce(p_body, '')) not between 1 and 500 then raise exception 'bad_post'; end if;
  insert into ml_posts (author_id, body) values (uid, p_body);
  return ml_feed_json(uid);
end $$;

create or replace function public.ml_write_comment(p_token uuid, p_post bigint, p_body text)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := ml_session_user(p_token);
begin
  p_body := trim(p_body);
  if char_length(coalesce(p_body, '')) not between 1 and 300 then raise exception 'bad_comment'; end if;
  if not exists (select 1 from ml_posts where id = p_post) then raise exception 'post_not_found'; end if;
  insert into ml_comments (post_id, author_id, body) values (p_post, uid, p_body);
  return ml_post_json(uid, p_post);
end $$;

-- 내 글 · 내 댓글 삭제
create or replace function public.ml_delete_post(p_token uuid, p_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := ml_session_user(p_token);
begin
  delete from ml_posts where id = p_id and author_id = uid;
  return ml_feed_json(uid);
end $$;

create or replace function public.ml_delete_comment(p_token uuid, p_id bigint)
returns json language plpgsql security definer set search_path = public as $$
declare uid uuid := ml_session_user(p_token); pid bigint;
begin
  delete from ml_comments where id = p_id and author_id = uid returning post_id into pid;
  if pid is null then raise exception 'post_not_found'; end if;
  return ml_post_json(uid, pid);
end $$;

-- 5) 권한: 브라우저(anon)는 아래 함수만 호출 가능 --------------------------------
revoke all on function
  public.ml_session_user(uuid), public.ml_nickname_free(text, uuid), public.ml_user_json(public.ml_users),
  public.ml_check_nickname(text), public.ml_signup(text, text, text, text), public.ml_login(text, text),
  public.ml_logout(uuid), public.ml_me(uuid), public.ml_update_profile(uuid, text, jsonb),
  public.ml_list_profiles(uuid), public.ml_delete_account(uuid, text),
  public.ml_check_target(uuid, text), public.ml_home_json(uuid), public.ml_home(uuid),
  public.ml_draw(uuid, text), public.ml_rate(uuid, text, int), public.ml_chat_request(uuid, text),
  public.ml_feed_json(uuid), public.ml_post_json(uuid, bigint), public.ml_feed(uuid), public.ml_post(uuid, bigint),
  public.ml_write_post(uuid, text), public.ml_write_comment(uuid, bigint, text),
  public.ml_delete_post(uuid, bigint), public.ml_delete_comment(uuid, bigint)
from public, anon, authenticated;

grant execute on function
  public.ml_check_nickname(text), public.ml_signup(text, text, text, text), public.ml_login(text, text),
  public.ml_logout(uuid), public.ml_me(uuid), public.ml_update_profile(uuid, text, jsonb),
  public.ml_list_profiles(uuid), public.ml_delete_account(uuid, text),
  public.ml_home(uuid), public.ml_draw(uuid, text), public.ml_rate(uuid, text, int), public.ml_chat_request(uuid, text),
  public.ml_feed(uuid), public.ml_post(uuid, bigint), public.ml_write_post(uuid, text), public.ml_write_comment(uuid, bigint, text),
  public.ml_delete_post(uuid, bigint), public.ml_delete_comment(uuid, bigint)
to anon, authenticated;
