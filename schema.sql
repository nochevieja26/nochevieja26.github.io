-- Nochevieja 2026 · base de datos para Supabase
-- Pega TODO este archivo en Supabase → SQL Editor → New query → Run.
-- Se puede volver a ejecutar cuando cambie: no borra datos ya guardados.
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
insert into public.settings (id, people_override, notes, pay_how)
values (1, 35, 'El alcohol lo trae cada uno.', 'Pon en el concepto «Nochevieja» y tu nombre.')
on conflict (id) do nothing;

-- Recaudadores: a cada persona se le asigna uno por sorteo equitativo
create table if not exists public.collectors (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  phone text not null default '' check (char_length(phone) <= 30),   -- número de Bizum
  active boolean not null default true,                               -- false = no recibe gente nueva
  created_at timestamptz not null default now()
);

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
alter table public.guests add column if not exists pay_method text not null default 'bizum';
alter table public.guests add column if not exists collector_id uuid references public.collectors(id) on delete set null;
do $$ begin
  alter table public.guests add constraint guests_pay_method_chk check (pay_method in ('bizum','efectivo'));
exception when duplicate_object then null; end $$;

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

alter table public.settings   enable row level security;
alter table public.collectors enable row level security;
alter table public.guests     enable row level security;
alter table public.items      enable row level security;
revoke all on public.settings, public.collectors, public.guests, public.items from anon, authenticated;

-- Versiones antiguas de funciones cuyos parámetros han cambiado
drop function if exists public._check_pin(text);
drop function if exists public.signup(text,text,text,text);
drop function if exists public.update_me(uuid,text,text,text,text);
drop function if exists public.admin_guest_save(text,uuid,text,text,text,text,boolean);

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
    'start_time',start_time,'end_time',end_time,'pay_how',pay_how,
    'notes',notes,'people_override',people_override,'has_pin',admin_pin_hash is not null,
    'collectors',(select count(*) from collectors where active))
  from settings where id = 1;
$$;

-- Sorteo equitativo: el recaudador activo con menos gente asignada
-- (sin contar a quien no viene); si hay empate, al azar.
create or replace function public._pick_collector()
returns uuid language sql volatile security definer set search_path = public as $$
  select c.id from collectors c
  left join guests g on g.collector_id = c.id and g.status <> 'no'
  where c.active
  group by c.id
  order by count(g.id), random()
  limit 1;
$$;

-- Asigna recaudador a quien no tenga (o lo tenga desactivado y aún no haya pagado)
create or replace function public._assign_missing()
returns int language plpgsql volatile security definer set search_path = public as $$
declare r record; n int := 0;
begin
  perform pg_advisory_xact_lock(2026);
  for r in
    select g.id from guests g left join collectors c on c.id = g.collector_id
    where g.status <> 'no' and (g.collector_id is null or (not c.active and not g.paid))
    order by g.created_at
  loop
    update guests set collector_id = public._pick_collector() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public._collector_json(p_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('name',name,'phone',phone) from collectors where id = p_id;
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

create or replace function public.signup(p_name text, p_phone text, p_status text, p_brings text, p_pay text)
returns uuid language plpgsql volatile security definer set search_path = public as $$
declare t uuid; st text := case when p_status in ('si','quiza','no') then p_status else 'si' end;
begin
  if char_length(trim(coalesce(p_name,''))) = 0 then raise exception 'Falta el nombre'; end if;
  if (select count(*) from guests) >= 300 then raise exception 'La lista está llena'; end if;
  perform pg_advisory_xact_lock(2026);
  insert into guests (name, phone, status, brings, pay_method, collector_id)
  values (left(trim(p_name),60), left(trim(coalesce(p_phone,'')),30), st,
          left(trim(coalesce(p_brings,'')),120),
          case when p_pay = 'efectivo' then 'efectivo' else 'bizum' end,
          case when st <> 'no' then public._pick_collector() end)
  returning token into t;
  return t;
end $$;

-- ---------- ficha personal ----------
create or replace function public.me(p_token uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('guest', json_build_object('name',name,'phone',phone,'status',status,'brings',brings,'paid',paid,'pay_method',pay_method),
                           'collector', public._collector_json(collector_id),
                           'event', public._event(), 'money', public._money())
  from guests where token = p_token;
$$;

create or replace function public.update_me(p_token uuid, p_name text, p_phone text, p_status text, p_brings text, p_pay text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare gid uuid;
begin
  if char_length(trim(coalesce(p_name,''))) = 0 then raise exception 'Falta el nombre'; end if;
  update guests set name = left(trim(p_name),60), phone = left(trim(coalesce(p_phone,'')),30),
    status = case when p_status in ('si','quiza','no') then p_status else status end,
    brings = left(trim(coalesce(p_brings,'')),120),
    pay_method = case when p_pay in ('bizum','efectivo') then p_pay else pay_method end
  where token = p_token returning id into gid;
  if gid is null then raise exception 'Enlace no válido'; end if;
  perform public._assign_missing();
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
declare e text := public._pin_error(p_pin); pp numeric;
begin
  if e is not null then return json_build_object('error', e); end if;
  pp := (public._money()->>'per_person')::numeric;
  return json_build_object(
    'event', public._event(), 'money', public._money(),
    'collectors', coalesce((select json_agg(x order by x.created_at) from (
       select c.id, c.name, c.phone, c.active, c.created_at,
              count(g.id) filter (where g.status <> 'no') assigned,
              count(g.id) filter (where g.status = 'si' and g.paid) paid,
              count(g.id) filter (where g.status = 'si' and not g.paid) unpaid,
              count(g.id) filter (where g.status <> 'no' and g.pay_method = 'efectivo') cash,
              round(count(g.id) filter (where g.status = 'si' and g.paid) * pp, 2) collected
       from collectors c left join guests g on g.collector_id = c.id
       group by c.id) x), '[]'::json),
    'guests', coalesce((select json_agg(json_build_object('id',id,'token',token,'name',name,'phone',phone,'status',status,'brings',brings,'paid',paid,'pay_method',pay_method,'collector_id',collector_id,'created_at',created_at) order by name) from guests), '[]'::json),
    'items', coalesce((select json_agg(json_build_object('id',id,'name',name,'cat',cat,'q',q,'p',p,'who',who,'done',done,'opt',opt,'ord',ord) order by ord, name) from items), '[]'::json));
end $$;

create or replace function public.admin_guest_save(p_pin text, p_id uuid, p_name text, p_phone text, p_status text, p_brings text, p_paid boolean, p_pay text, p_collector uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); r uuid;
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then return json_build_object('error','Falta el nombre'); end if;
  if p_id is null then
    insert into guests (name, phone, status, brings, paid, pay_method, collector_id)
    values (left(trim(p_name),60), left(trim(coalesce(p_phone,'')),30),
            case when p_status in ('si','quiza','no') then p_status else 'si' end,
            left(trim(coalesce(p_brings,'')),120), coalesce(p_paid,false),
            case when p_pay = 'efectivo' then 'efectivo' else 'bizum' end, p_collector)
    returning id into r;
  else
    update guests set name = left(trim(p_name),60), phone = left(trim(coalesce(p_phone,'')),30),
      status = case when p_status in ('si','quiza','no') then p_status else status end,
      brings = left(trim(coalesce(p_brings,'')),120), paid = coalesce(p_paid, paid),
      pay_method = case when p_pay in ('bizum','efectivo') then p_pay else pay_method end,
      collector_id = p_collector
    where id = p_id returning id into r;
  end if;
  perform public._assign_missing();
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

create or replace function public.admin_collector_save(p_pin text, p_id uuid, p_name text, p_phone text, p_active boolean)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); r uuid; n int;
begin
  if e is not null then return json_build_object('error', e); end if;
  if char_length(trim(coalesce(p_name,''))) = 0 then return json_build_object('error','Falta el nombre'); end if;
  if p_id is null then
    if (select count(*) from collectors) >= 10 then return json_build_object('error','Máximo 10 recaudadores'); end if;
    insert into collectors (name, phone, active) values (left(trim(p_name),40), left(trim(coalesce(p_phone,'')),30), coalesce(p_active,true))
    returning id into r;
  else
    update collectors set name = left(trim(p_name),40), phone = left(trim(coalesce(p_phone,'')),30), active = coalesce(p_active, active)
    where id = p_id returning id into r;
  end if;
  n := public._assign_missing();
  return json_build_object('id', r, 'moved', n);
end $$;

-- Borrar un recaudador: solo si nadie le ha pagado todavía; su gente se reparte entre los demás
create or replace function public.admin_collector_delete(p_pin text, p_id uuid)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); n int;
begin
  if e is not null then return json_build_object('error', e); end if;
  if exists (select 1 from guests where collector_id = p_id and paid) then
    return json_build_object('error','Ya le han pagado: desactívalo en vez de borrarlo, así no se pierden las cuentas');
  end if;
  update guests set collector_id = null where collector_id = p_id;
  delete from collectors where id = p_id;
  n := public._assign_missing();
  return json_build_object('ok', true, 'moved', n);
end $$;

-- Volver a sortear: reparte de forma equitativa a toda la gente que aún NO ha pagado
create or replace function public.admin_collectors_reshuffle(p_pin text)
returns json language plpgsql volatile security definer set search_path = public as $$
declare e text := public._pin_error(p_pin); n int;
begin
  if e is not null then return json_build_object('error', e); end if;
  if not exists (select 1 from collectors where active) then return json_build_object('error','No hay recaudadores activos'); end if;
  update guests set collector_id = null where not paid;
  n := public._assign_missing();
  return json_build_object('ok', true, 'moved', n);
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
    pay_how    = left(coalesce(p->>'pay_how', pay_how),200),
    notes      = left(coalesce(p->>'notes', notes),400),
    people_override = case when p ? 'people_override' then nullif(p->>'people_override','')::int else people_override end
  where id = 1;
  return json_build_object('ok', true);
end $$;

-- ---------- permisos ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.public_info(), public.signup(text,text,text,text,text),
  public.me(uuid), public.update_me(uuid,text,text,text,text,text),
  public.admin_setup_pin(text), public.admin_change_pin(text,text), public.admin_state(text),
  public.admin_guest_save(text,uuid,text,text,text,text,boolean,text,uuid), public.admin_guest_delete(text,uuid),
  public.admin_collector_save(text,uuid,text,text,boolean), public.admin_collector_delete(text,uuid),
  public.admin_collectors_reshuffle(text),
  public.admin_item_save(text,uuid,text,text,numeric,numeric,text,boolean,boolean), public.admin_item_delete(text,uuid),
  public.admin_settings_save(text,jsonb)
to anon, authenticated;
