-- =====================================================================
-- Lista de Compras: esquema inicial
--
-- Como usar: cole este arquivo inteiro no SQL Editor do Supabase e
-- clique em "Run". Ele é seguro para rodar uma única vez num projeto novo.
--
-- Decisões pensadas para o modo offline (etapa 4):
--   * IDs são UUIDs que o próprio celular pode gerar, sem esperar o servidor.
--   * Toda tabela sincronizável tem updated_at (para saber o que mudou)
--     e deleted_at (exclusão "suave", para que outros aparelhos fiquem
--     sabendo que algo foi apagado).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Perfis: um por usuário do Google, criado automaticamente no 1º login
-- ---------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  email       text not null unique,
  full_name   text,
  avatar_url  text,
  created_at  timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    lower(new.email),
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'avatar_url'
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Listas: o criador é o dono
-- ---------------------------------------------------------------------
create table public.lists (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 80),
  category    text not null default 'mercado'
              check (category in ('mercado', 'acougue', 'feira', 'padaria', 'farmacia', 'outro')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

-- ---------------------------------------------------------------------
-- Membros: quem pode ver e editar cada lista (o dono também entra aqui)
-- ---------------------------------------------------------------------
create table public.list_members (
  list_id     uuid not null references public.lists (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  role        text not null default 'editor' check (role in ('owner', 'editor')),
  added_at    timestamptz not null default now(),
  primary key (list_id, user_id)
);

create index list_members_user_idx on public.list_members (user_id);

-- ---------------------------------------------------------------------
-- Itens de cada lista
-- ---------------------------------------------------------------------
create table public.items (
  id          uuid primary key default gen_random_uuid(),
  list_id     uuid not null references public.lists (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 120),
  quantity    numeric(10, 3),
  unit        text,
  note        text,
  checked     boolean not null default false,
  created_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted_at  timestamptz
);

create index items_list_idx on public.items (list_id);
create index items_updated_idx on public.items (updated_at);

-- ---------------------------------------------------------------------
-- Produtos salvos: catálogo pessoal para reaproveitar ao montar listas
-- ---------------------------------------------------------------------
create table public.products (
  id            uuid primary key default gen_random_uuid(),
  owner_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name          text not null check (char_length(name) between 1 and 120),
  default_unit  text,
  category      text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz,
  unique (owner_id, name)
);

-- ---------------------------------------------------------------------
-- updated_at sempre atualizado pelo servidor
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger lists_touch    before update on public.lists    for each row execute function public.touch_updated_at();
create trigger items_touch    before update on public.items    for each row execute function public.touch_updated_at();
create trigger products_touch before update on public.products for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- Ao criar uma lista, o dono vira membro automaticamente
-- ---------------------------------------------------------------------
create or replace function public.add_owner_as_member()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.list_members (list_id, user_id, role)
  values (new.id, new.owner_id, 'owner');
  return new;
end;
$$;

create trigger lists_add_owner
  after insert on public.lists
  for each row execute function public.add_owner_as_member();

-- ---------------------------------------------------------------------
-- Funções auxiliares usadas pelas regras de segurança.
-- São "security definer" para evitar recursão nas políticas.
-- ---------------------------------------------------------------------
create or replace function public.is_list_member(p_list_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.list_members
    where list_id = p_list_id and user_id = auth.uid()
  );
$$;

create or replace function public.is_list_owner(p_list_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.lists
    where id = p_list_id and owner_id = auth.uid()
  );
$$;

create or replace function public.shares_a_list_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.list_members mine
    join public.list_members theirs on theirs.list_id = mine.list_id
    where mine.user_id = auth.uid() and theirs.user_id = p_user_id
  );
$$;

-- ---------------------------------------------------------------------
-- Compartilhar uma lista pelo e-mail da conta Google (usado na etapa 3).
-- Só o dono consegue; a pessoa precisa ter entrado no app ao menos uma vez.
-- ---------------------------------------------------------------------
create or replace function public.share_list(p_list_id uuid, p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid;
begin
  if not public.is_list_owner(p_list_id) then
    raise exception 'Somente o dono da lista pode compartilhá-la';
  end if;

  select id into v_user_id from public.profiles where email = lower(trim(p_email));
  if v_user_id is null then
    raise exception 'Nenhum usuário com este e-mail. Peça para a pessoa entrar no app uma vez.';
  end if;

  insert into public.list_members (list_id, user_id, role)
  values (p_list_id, v_user_id, 'editor')
  on conflict (list_id, user_id) do nothing;

  return v_user_id;
end;
$$;

revoke execute on function public.share_list(uuid, text) from public, anon;
grant execute on function public.share_list(uuid, text) to authenticated;

-- ---------------------------------------------------------------------
-- Regras de segurança (Row Level Security)
-- Sem uma política que permita, o acesso é negado.
-- ---------------------------------------------------------------------
alter table public.profiles     enable row level security;
alter table public.lists        enable row level security;
alter table public.list_members enable row level security;
alter table public.items        enable row level security;
alter table public.products     enable row level security;

-- Perfis: vejo o meu e o de quem divide lista comigo
create policy "ver perfis próprios e de colegas" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.shares_a_list_with(id));

create policy "editar o próprio perfil" on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Listas: membros veem; qualquer um cria a sua; só o dono altera ou apaga
create policy "membros veem a lista" on public.lists
  for select to authenticated
  using (owner_id = auth.uid() or public.is_list_member(id));

create policy "criar lista própria" on public.lists
  for insert to authenticated
  with check (owner_id = auth.uid());

create policy "dono altera a lista" on public.lists
  for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy "dono apaga a lista" on public.lists
  for delete to authenticated
  using (owner_id = auth.uid());

-- Membros: quem é da lista vê os colegas; só o dono adiciona;
-- o dono remove qualquer um (menos ele mesmo) e cada um pode sair
create policy "membros veem colegas" on public.list_members
  for select to authenticated
  using (public.is_list_member(list_id));

create policy "dono adiciona membros" on public.list_members
  for insert to authenticated
  with check (public.is_list_owner(list_id) and role = 'editor');

create policy "dono remove ou membro sai" on public.list_members
  for delete to authenticated
  using (
    role <> 'owner'
    and (public.is_list_owner(list_id) or user_id = auth.uid())
  );

-- Itens: todos os membros da lista leem e escrevem
create policy "membros veem itens" on public.items
  for select to authenticated
  using (public.is_list_member(list_id));

create policy "membros adicionam itens" on public.items
  for insert to authenticated
  with check (public.is_list_member(list_id));

create policy "membros alteram itens" on public.items
  for update to authenticated
  using (public.is_list_member(list_id)) with check (public.is_list_member(list_id));

create policy "membros apagam itens" on public.items
  for delete to authenticated
  using (public.is_list_member(list_id));

-- Produtos: catálogo de cada um
create policy "dono gerencia seus produtos" on public.products
  for all to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- ---------------------------------------------------------------------
-- Tempo real: avisar os aparelhos quando algo mudar
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table public.lists, public.list_members, public.items;
