# Claude Dock Station

Um dock no macOS que mostra as sessões vivas do Claude Code em cards, com
miniatura da janela e badge de status. Motor em Hammerspoon (Lua); o status vem
de hooks do Claude Code que escrevem um arquivo de estado por sessão.

## Idioma

- **UI e README: pt-BR.** É a língua do projeto. Não traduza para inglês.
- **Comentários de código e mensagens de commit: inglês.**

## Fixtures de teste — vocabulário obrigatório

Os testes deste repo modelam projetos, hosts e caminhos. **Use sempre o
vocabulário genérico abaixo. Nunca escreva nome de cliente, de empresa, host SSH
real, caminho de máquina real (`/Users/<alguém>`, `/opt/<alguém>`) ou título de
conversa de trabalho real numa fixture** — nem em comentário de teste.

Isto não é preferência de estilo: fixtures com dado real envelhecem mal, acoplam
o teste a uma máquina que ninguém mais tem, e documentam para o leitor um caso
que ele não consegue reproduzir. O vocabulário abaixo cobre todos os formatos que
a lógica de nomeação precisa distinguir — se você precisa de um caso novo,
estenda-o em vez de recorrer a um nome real.

| Nome | Papel que ele modela |
|---|---|
| `webapp` | projeto em deploy layout (`/opt/apps/webapp/production/repo`), **sem** repo git (`root=""`) |
| `webapp-core` | colisão de prefixo com `webapp` — no match por título (`title_has_segment`), o word-boundary garante que `webapp` **não** casa dentro dele; **isso não vale** pro corroborar por slug (`slug_has_folder`), que casa `webapp` dentro de `-webapp-core-...` |
| `acme` | cliente cuja raiz de repo **é** o wrapper de ambiente (`/opt/clients/acme/production`), mas cuja janela abre em `/opt/clients/acme` |
| `crm` | projeto sem repo git, usado nos casos de scratchpad |
| `dash` | projeto **com** raiz de repo (`/opt/apps/dash`) e subpasta profunda (`supabase/functions`) |
| `globex` | projeto folha (o caminho inteiro é o projeto, `/opt/clients/globex`), **sem repo git** (`root=""`), com sessões rodando em subpastas fundas e não-genéricas (`docs/<x>/<y>`) |
| `arcade`, `legal-app` | subprojetos sob uma raiz de dev (`/opt/dev/...`) |
| `toolbox` | usado no teste de match case-insensitive |
| `my-vps` | host SSH remoto |
| `/Users/dev`, `/opt/dev` | caminhos de máquina/usuário |

Títulos de conversa nas fixtures são genéricos e em português (`Preparar a
proposta comercial`, `Revisar a página inicial`). Dois cuidados ao criar um:

- **Título truncado é prefixo exato.** Um título de janela terminando em `…` tem
  que ser prefixo literal do título completo da sessão, ou os testes de
  corroboração por slug quebram.
- **Mantenha os acentos.** Os títulos acentuados são a única cobertura de UTF-8
  do truncamento e do match de slug — é onde bug de multibyte se esconde.

### O caminho da fixture carrega significado — não encurte

Vários testes dependem da **profundidade** e da **genericidade** dos segmentos,
não só dos nomes. `project_candidates` tem teto de 2 candidatos e pula o que está
na lista `GENERIC` (`opt`, `apps`, `clients`, `production`, `repo`, `dev`,
`worktrees`, `main`…). Consequências ao mexer numa fixture:

- **Um nome novo nunca pode cair na lista `GENERIC`.** Renomear uma pasta para
  `dev`, `repo`, `staging` ou `main` faz o segmento ser pulado e muda o que o
  teste exercita — em silêncio, com a suíte verde.
- **Segmentos não-genéricos intermediários gastam slots de propósito.** Em
  `/opt/clients/globex/docs/Campanha-Aniversario/_anexos`, o `docs` não é
  genérico: ele consome um slot para que o teto de 2 nunca alcance `globex`.
  Encurtar esse caminho faz o teste passar sem provar nada.
- **Em testes de janelas aninhadas, a ordem do array é a prova.** O ancestral é
  listado primeiro justamente para demonstrar que vence a janela mais funda, não
  a primeira que casa. Inverter a ordem esvazia o teste.

O padrão para checar tudo isso é mutação: quebre de propósito o código que a
fixture cobre e confirme que o teste falha.

## Testes

```bash
lua tests/core_spec.lua    # engine — deve reportar "N passed, 0 failed"
bash tests/test_emit.sh    # hooks
bash tests/test_install.sh # instalador
```

Só `hammerspoon/core.lua` roda sob `lua` puro; o resto precisa do Hammerspoon.
Para o arquivo de entrada, o portão possível é sintático:

```bash
lua -e "assert(loadfile('hammerspoon/claude-dock-station.lua'))"
```

**As fixtures são dados puros — a suíte verde não prova que uma mudança nelas
está correta.** Ao alterar fixture, verifique que o teste ainda exercita o que o
nome dele promete. A ferramenta para isso é mutação: quebre de propósito o código
que o teste cobre e confirme que ele falha. Se continuar verde, o teste morreu.

## Estrutura

- `hammerspoon/core.lua` — lógica pura (nomeação de projeto, match de janela,
  deck). É o que os testes cobrem.
- `hammerspoon/claude-dock-station.lua` — cascas, config, timers. Termina com um
  bloco `-- boot` e `return M`; **defina `M.xxx` novos ANTES do `-- boot`**.
- `hooks/emit.sh` — roda na máquina de cada sessão e escreve o estado.
- `hammerspoon/ui/` — renderers HTML.

## Config

Defaults vivem em `DEFAULTS` no `claude-dock-station.lua`; a config do usuário
(`~/.claude-dock-station/config.json`) sobrepõe via `merge_config`. Os defaults
não devem apontar para máquina nenhuma — `remotes` nasce vazio, e quem quiser
puxar sessões remotas configura o próprio host.

Ao adicionar uma chave nova em `DEFAULTS`, confira se `settings.html` a preserva
no `save()`: o painel reescreve o JSON inteiro, então uma chave esquecida ali é
resetada silenciosamente a cada Salvar.
