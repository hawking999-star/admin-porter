/**
 * Extrai uma mensagem legível de erros vindos do Supabase/PostgREST.
 *
 * Os erros do supabase-js (PostgrestError) são objetos simples — NÃO são
 * instâncias de `Error` — então `err instanceof Error` é falso e o app acabava
 * mostrando sempre "Erro inesperado", escondendo a causa real (ex.: uma versão
 * bloqueada que não pode ser editada).
 *
 * Aqui traduzimos os códigos levantados pelas RPCs (`raise exception '...'`)
 * para um texto claro em português e, quando não houver tradução, devolvemos a
 * própria mensagem do erro.
 */

const RPC_MESSAGES: Record<string, string> = {
  // app_releases (Atualizações)
  release_locked: "Esta versão não está mais em rascunho/teste e não pode ser editada. Atualize a página para ver o status atual.",
  release_not_found: "Versão não encontrada. Ela pode ter sido removida ou atualizada por outra pessoa.",
  invalid_edit_status: 'Status inválido. Uma versão só pode ficar em "Rascunho" ou "Teste".',
  invalid_initial_status: 'Status inicial inválido. Escolha "Rascunho" ou "Teste".',
  invalid_version: "Versão inválida. Use o formato X.Y.Z (ex.: 1.0.6).",
  title_required: "O título é obrigatório.",
  block_reason_required: "Informe o motivo do bloqueio.",
  invalid_release_status: "A versão já está bloqueada ou substituída.",
  not_release_admin: "Você não tem permissão para gerenciar versões do app.",
  // promoção de acesso (app <-> painel)
  operator_has_no_login: "Este operador não tem login vinculado, então não dá para promover ao painel.",
  operator_not_found: "Operador não encontrado. Atualize a página e tente de novo.",
  admin_user_not_found: "Acesso não encontrado. Atualize a página e tente de novo.",
  admin_has_no_login: "Este acesso não tem login vinculado no Supabase Auth.",
  already_has_app_access: "Esta pessoa já tem acesso ao app.",
  username_required: "Informe o usuário para o login no app.",
  username_invalid: "Usuário inválido. Use letras minúsculas, números, ponto, hífen ou underline (3 a 60).",
  username_taken: "Esse usuário já está em uso. Escolha outro.",
  operator_role_invalid: "Cargo do operador inválido.",
  session_policy_invalid: "Política de sessão inválida.",
  unit_not_found_or_inactive: "Condomínio não encontrado ou inativo.",
  // permissões / genéricos
  forbidden: "Você não tem permissão para executar esta ação.",
  unauthorized: "Sessão expirada. Entre novamente para continuar.",
};

/** Mensagens do próprio Postgres, por código SQLSTATE, para casos comuns. */
const PG_CODE_MESSAGES: Record<string, string> = {
  "23505": "Já existe um registro com esses dados (valor duplicado).",
  "23503": "Operação inválida: existe um vínculo com outro registro.",
  "23514": "Os dados não atendem a uma regra de validação do banco.",
  "42501": "Você não tem permissão para executar esta ação.",
  PGRST301: "Sessão expirada. Entre novamente para continuar.",
};

function pick(obj: unknown, key: string): string | undefined {
  if (obj && typeof obj === "object" && key in obj) {
    const value = (obj as Record<string, unknown>)[key];
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return undefined;
}

/**
 * Devolve a melhor mensagem possível para exibir ao usuário.
 * @param fallback texto usado quando nada pôde ser extraído do erro.
 */
export function errorMessage(err: unknown, fallback = "Erro inesperado. Tente novamente."): string {
  if (!err) return fallback;

  const raw = pick(err, "message") ?? (err instanceof Error ? err.message : undefined);
  const code = pick(err, "code");

  // 1. Códigos levantados pelas RPCs chegam como a própria mensagem.
  if (raw && RPC_MESSAGES[raw]) return RPC_MESSAGES[raw];
  // 2. Código SQLSTATE / PostgREST.
  if (code && PG_CODE_MESSAGES[code]) return PG_CODE_MESSAGES[code];
  // 3. Mensagem crua do banco, se houver.
  if (raw) return raw;

  return fallback;
}

/**
 * Indica que o erro veio de tentar salvar/editar uma release que não está mais
 * em rascunho/teste (bloqueada, aprovada, liberada) ou que não existe mais.
 * Nesses casos o formulário aberto está desatualizado e deve ser fechado.
 */
export function isNonEditableReleaseError(err: unknown): boolean {
  const raw = pick(err, "message") ?? (err instanceof Error ? err.message : undefined);
  return raw === "release_locked" || raw === "release_not_found" || raw === "invalid_edit_status";
}
