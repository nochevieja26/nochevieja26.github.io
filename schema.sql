-- Nochevieja 2026 · base de datos para Supabase
-- Pega TODO este archivo en Supabase → SQL Editor → New query → Run.
-- Se puede volver a ejecutar: no borra datos ya guardados.
--
-- Seguridad: las tablas están cerradas (RLS sin políticas). La web solo usa
-- las funciones de abajo:
--   · públicas: ver la info de la fiesta y apuntarse
--   · con enlace personal (token): ver y editar la propia ficha
--   · con PIN de gestor: todo lo demás

create extension if not exists pgcrypto with schema extensions;

-- ---------- tablas ----------
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  event_name text not null default 'Nochevieja 2026',
  place text not null default '',
  addr text not null default '',
  start_time text not null default '22:00',
  end_time text not null default '',
  pay_to text not null default '',
  pay_how text not null default '',
  notes text not null default '',
  people_override int,            -- null = repartir entre los confirmados
  admin_pin_hash text,            -- null = PIN aún sin crear
  fail_count int not null default 0,
  fail_since timestamptz
);
insert into public.settings (id, people_override, notes)
values (1, 35, 'El alcohol lo trae cada uno.')
on conflict (id) do nothing;

create table if not exists public.guests (
  id uuid primary key default gen_random_uuid(),
  token uuid not null unique default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  phone text not null default '' check (char_length(phone) <= 30),
  status text not null default 'si' check (status in ('si','quiza','no')),
  brings text not null default '' check (char_length(brings) <= 120),
  paid boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.items (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 120),
  cat text not null default 'Otros',
  q numeric not null default 1 check (q >= 0),
  p numeric not null default 0 check (p >= 0),
  who text not null default '',
  done boolean not null default false,
  opt boolean not null default false,   -- true = "si sobra dinero", no cuenta
  ord int not null default 0
);
insert into public.items (name, cat, q, p, ord, opt)
select * from (values
  ('Alquiler del local','Local',1,500,1,false),
  ('Vasos de cubata (pack de 100)','Bebida',2,6,2,false),
  ('Hielo (bolsa de 2 kg)','Bebida',15,1.5,3,false),
  ('Chuches surtidas (bolsa de 1 kg)','Picoteo',4,7,4,false),
  ('Alquiler de altavoces','Música',1,90,5,false),
  ('Refresco para mezclar (botella de 2 L)','Bebida',35,1,6,true)
) v(name,cat,q,p,ord,opt)
where not exists (select 1 from public.items);

alter table public.settings enable row level security;
alter table public.guests   enable row level security;
alter table public.items    enable row level security;
revoke all on public.settings, public.guests, public.items from anon, authenticated;

-- ---------- cálculos ----------
create or replace function public._money()
returns json language sql stable security definer set search_path = public as $$
  with t as (
    select coalesce(sum(q*p) filter (where not opt),0) total,
           coalesce(sum(q*p) filter (where not opt and not done),0) pending,
           coalesce(sum(q*p) filter (where opt),0) extra
    from items),
  g as (
    select count(*) filter (where status='si') si,
           count(*) filter (where status='quiza') quiza,
           count(*) filter (where status='si' and paid) paid
    from guests),
  d as (
    select greatest(1, coalesce(s.people_override, g.si)) n, s.people_override
    from settings s, g where s.id = 1)
  select json_build_object(
    'total', t.total, 'pending', t.pending, 'extra', t.extra,
    'people', d.n, 'by_confirmed', d.people_override is null,
    'per_person', ceil(t.total / d.n * 100) / 100,
    'extra_per_person', ceil(t.extra / d.n * 100) / 100,
    'si', g.si, 'quiza', g.quiza, 'paid', g.paid,
    'collected', round(g.paid * ceil(t.total / d.n * 100) / 100, 2))
  from t, g, d;
$$;

create or replace function public._event()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('event_name',event_name,'place',place,'addr',addr,
    'start_time',start_time,'end_time',end_time,'pay_to',pay_to,'pay_how',pay_how,
    'notes',notes,'people_override',people_override,'has_pin',admin_pin_hash is not null)
  from settings where id = 1;
$$;

-- ---------- público ----------
create or replace function public.public_info()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'event', public._event(),
    'money', public._money(),
    'coming', coalesce((select json_agg(json_build_object('name',name,'status',status) order by name)
                        from guests where status <> 'no'), '[]'::json),
    'items', coalesce((select json_agg(json_build_object('name',name,'cat',cat,'q',q,'p',p,'done',done,'opt',opt,'who',who) order by ord, name)
                       from items), '[]'::json));
$$;

create or replace function public.signup(p_name text, p_phone text, p_status text, p_brings text)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare t uuid;
begin
  if (select count(*) from guests) >= 300 then raise exception 'La lista está llena'; end if;
  insert into guests (name, phone, status, brings)
  values (left(trim(p_name),60), left(trim(coalesce(p_phone,'')),30),
          case when p_status in ('si','quiza','no') then p_status else 'si' end,
          left(trim(coalesce(p_brings,'')),120))
  returning token into t;
  return t;
end $$;

-- ---------- ficha personal ----------
create or replace function public.me(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('guest', json_build_object('name',name,'phone',phone,'status',status,'brings',brings,'paid',paid),
                           'event', public._event(), 'money', public._money())
  from guests where token = p_token;
$$;

create or replace function public.update_me(p_token uuid, p_name text, p_phone text, p_status text, p_brings text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if char_length(trim(coalesce(p_name,''))) = 0 then raise exception 'Falta el nombre'; end if;
  update guests set name = left(trim(p_name),60), phone = left(trim(coalesce(p_phone,'')),30),
    status = case when p_status in ('si','quiza','no') then p_status else status end,
    brings = left(trim(coalesce(p_brings,'')),120)
  where token = p_token;
  if not found then raise exception 'Enlace no válido'; end if;
end $$;

-- ---------- gestores (PIN) ----------
-- Las funciones de gestión no lanzan error con un PIN incorrecto: devuelven
-- {"error": "..."} para que el contador de intentos fallidos se guarde.
create or replace function public._pin_error(p_pin text)
returns text language plpgsql volatile security definer set search_path = public, extensions as $$
declare s settings;
begin
  select * into s from settings where id = 1 for update;
  if s.admin_pin_hash is null then return 'Todavía no hay PIN de gestor'; end if;
  if s.fail_count >= 8 and s.fail_since > now() - interval '15 minutes' then
    return 'Demasiados intentos. Espera 15 minutos.';
  end if;
  if crypt(coalesce(p_pin,''), s.admin_pin_hash) <> s.admin_pin_hash then
    update settings set fail_count = case when fail_since > now() - interval '15 minutes' then fail_count + 1 else 1 end,
                        fail_since = case when fail_since > now() - interval '15 minutes' then fail_since else now() end
    where id = 1;
    return 'PIN incorrecto';
  end if;
  update settings set fail_count = 0, fail_since = null where id = 1 and fail_count > 0;
  return null;
end $$;

create or replace function public.admin_setup_pin(p_new text)
returns json language plpgsql volatile security definer set search_path = public, extensions as $$
begin
  if char_length(coalesce(p_new,'')) < 6 then return json_build_object('error','El PIN debe tener al menos 6 caracteres'); end if;
  update settings set admin_pin_hash = crypt(p_new, gen_salt('bf', 8)) where id = 1 and admin_pin_hash is null;
  if not found then return json_build_object('error','El PIN ya está creado'); end if;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_change_pin(p_pin text, p_new text)
returns json language plpgsql volatile security definer set search_path = public, extensions as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(coalesce(p_new,'')) < 6 then return json_build_object('error','El PIN debe tener al menos 6 caracteres'); end if;
  update settings set admin_pin_hash = crypt(p_new, gen_salt('bf', 8)) where id = 1;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_state(p_pin text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  return json_build_object(
    'event', public._event(), 'money', public._money(),
    'guests', coalesce((select json_agg(json_build_object('id',id,'token',token,'name',name,'phone',phone,'status',status,'brings',brings,'paid',paid,'created_at',created_at) order by name) from guests), '[]'::json),
    'items', coalesce((select json_agg(json_build_object('id',id,'name',name,'cat',cat,'q',q,'p',p,'who',who,'done',done,'opt',opt,'ord',ord) order by ord, name) from items), '[]'::json));
end $$;

create or replace function public.admin_guest_save(p_pin text, p_id uuid, p_name text, p_phone text, p_status text, p_brings text, p_paid boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); r uuid;
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then return json_build_object('error','Falta el nombre'); end if;
  if p_id is null then
    insert into guests (name, phone, status, brings, paid)
    values (left(trim(p_name),60), left(trim(coalesce(p_phone,'')),30),
            case when p_status in ('si','quiza','no') then p_status else 'si' end,
            left(trim(coalesce(p_brings,'')),120), coalesce(p_paid,false))
    returning id into r;
  else
    update guests set name = left(trim(p_name),60), phone = left(trim(coalesce(p_phone,'')),30),
      status = case when p_status in ('si','quiza','no') then p_status else status end,
      brings = left(trim(coalesce(p_brings,'')),120), paid = coalesce(p_paid, paid)
    where id = p_id returning id into r;
  end if;
  return json_build_object('id', r);
end $$;

create or replace function public.admin_guest_delete(p_pin text, p_id uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  delete from guests where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_item_save(p_pin text, p_id uuid, p_name text, p_cat text, p_q numeric, p_p numeric, p_who text, p_done boolean, p_opt boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); r uuid;
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then return json_build_object('error','Falta el nombre'); end if;
  if p_id is null then
    insert into items (name, cat, q, p, who, done, opt, ord)
    values (left(trim(p_name),120), coalesce(nullif(p_cat,''),'Otros'), greatest(coalesce(p_q,0),0), greatest(coalesce(p_p,0),0),
            left(coalesce(p_who,''),40), coalesce(p_done,false), coalesce(p_opt,false),
            coalesce((select max(ord) from items),0) + 1)
    returning id into r;
  else
    update items set name = left(trim(p_name),120), cat = coalesce(nullif(p_cat,''),'Otros'),
      q = greatest(coalesce(p_q,0),0), p = greatest(coalesce(p_p,0),0), who = left(coalesce(p_who,''),40),
      done = coalesce(p_done,false), opt = coalesce(p_opt,false)
    where id = p_id returning id into r;
  end if;
  return json_build_object('id', r);
end $$;

create or replace function public.admin_item_delete(p_pin text, p_id uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  delete from items where id = p_id;
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_settings_save(p_pin text, p jsonb)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin);
begin
  if e is not null then return json_build_object('error', e); end if;
  update settings set
    event_name = left(coalesce(p->>'event_name', event_name),60),
    place      = left(coalesce(p->>'place', place),80),
    addr       = left(coalesce(p->>'addr', addr),160),
    start_time = left(coalesce(p->>'start_time', start_time),10),
    end_time   = left(coalesce(p->>'end_time', end_time),40),
    pay_to     = left(coalesce(p->>'pay_to', pay_to),80),
    pay_how    = left(coalesce(p->>'pay_how', pay_how),200),
    notes      = left(coalesce(p->>'notes', notes),400),
    people_override = case when p ? 'people_override' then nullif(p->>'people_override','')::int else people_override end
  where id = 1;
  return json_build_object('ok', true);
end $$;

drop function if exists public._check_pin(text);

-- ---------- permisos ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.public_info(), public.signup(text,text,text,text),
  public.me(uuid), public.update_me(uuid,text,text,text,text),
  public.admin_setup_pin(text), public.admin_change_pin(text,text), public.admin_state(text),
  public.admin_guest_save(text,uuid,text,text,text,text,boolean), public.admin_guest_delete(text,uuid),
  public.admin_item_save(text,uuid,text,text,numeric,numeric,text,boolean,boolean), public.admin_item_delete(text,uuid),
  public.admin_settings_save(text,jsonb)
to anon, authenticated;
