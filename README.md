# Claude Dock Station

Um "dock" no macOS que mostra, em cards, todas as sessões do Claude Code que
estão vivas agora — com miniatura ao vivo da janela do VS Code de cada uma e
um badge de status:

- ⚠️ **precisa de você** — a sessão parou numa `Notification` (permissão/decisão pendente)
- 🛠️ **trabalhando** — entre o prompt e o `Stop`, mostrando a ferramenta atual
- ✅ **terminou** — turno concluído, esperando o próximo prompt
- 🏖️ **idle** — estado transitório logo após o `SessionStart`; vira 🛠️ no próximo prompt

Clicar num card foca a janela do VS Code correspondente. O motor roda em
Hammerspoon; o status vem de hooks do Claude Code que escrevem um arquivo de
estado por sessão. Há duas cascas independentes — **Overlay** (hotkey) e
**Menu bar** — mais uma **Vista na tela** por vez (**Painel fixo**, **Mosaico**
ou **Barra**), todas detalhadas na seção **Cascas (Shells)** abaixo, e um painel
de administração:

- **Painel de configurações** — janela HTML onde dá pra trocar o hotkey
  (gravador "clique e aperte"), ligar/desligar overlay e menu bar, escolher a
  **Vista na tela** e o **monitor** dela, desligar miniaturas, trocar o tema,
  mudar o app host e ver o diagnóstico de permissões — tudo aplicado na hora,
  sem reiniciar o Hammerspoon.

## Cascas (Shells)

**Overlay** (hotkey) e **Menu bar** são independentes. As cascas que ocupam a
tela — **Painel fixo**, **Mosaico** e **Barra** — são mutuamente exclusivas:
você escolhe **uma** em "Vista na tela", e ela usa um **único monitor**
compartilhado. O Overlay usa sempre a tela principal; o Menu bar não tem
conceito de monitor.

### Overlay

Hotkey global (default `Cmd+Shift+Space`) abre o grid em tela cheia por cima de tudo; clica → foca → some. O "alt-tab do Claude".

### Painel fixo

Janela always-on-top num canto da tela, atualizando ao vivo. Configurável:
- **Canto** — top-left, top-right, bottom-left, bottom-right.

### Menu bar

Ícone 🤖 com contador (ex: `🤖 3`) e um dropdown com a lista de sessões e atalho para "⚙️ Configurações".

### Mosaico

Uma faixa de largura total com os cards em **grade** — a mesma informação do
painel (emoji+projeto, subtítulo, detalhe·idade·host) com a miniatura em formato
quadrado no topo. Configurável em "Vista na tela":

- **Borda** — Superior (padrão) ou Inferior.
- **Colunas** — número fixo de colunas, ou `0` para auto-ajustar pelo tamanho do quadrado.
- **Tamanho do quadrado** — tamanho da miniatura em px (padrão 150).
- **Máx cards** — limita quantos aparecem (`0` = todos).

A altura da faixa é medida pelo próprio renderer (funciona com ou sem miniatura),
cresce conforme as sessões entram e saem até ~60% da tela, e então rola.

### Barra

Uma tira fina na borda (superior ou inferior) mostrando um chip por sessão
(**emoji de status + título da conversa**), com rolagem horizontal. Clique num
chip para focar aquela janela. Configurável: **Borda** (Superior/Inferior),
**Altura**, **Máx cards**.

O **monitor** dessas três vistas é definido num único campo **Monitor** em
"Vista na tela".

## Recentes (reabrir janela)

O **ícone 🤖 da barra de menu** é o launcher/histórico: lista as **janelas**
(pastas do VS Code) que o dock já viu, mais recente primeiro, com **🟢 nas que
estão abertas agora** e **🕘 nas fechadas**. Clique numa aberta pra focá-la; numa
fechada, o dock **reabre a pasta no VS Code** — janela **Remote-SSH** pro host
certo (a VPS) se for remota, ou local caso contrário.

- **Janelas, não abas**: os recentes são deduplicados por **pasta do projeto
  resolvido** (host + a pasta do sinal que venceu — ver "Como o nome do projeto é
  decidido"), então as conversas de uma janela normalmente viram **uma** entrada.
  Normalmente, não sempre: se uma subpasta tem um sinal mais fundo que a pasta da
  janela — um container, ou um repo aninhado (worktree, submodule) — ela ganha
  entrada própria. Scratchpads e pastas temporárias são ignorados. Guardado em
  `~/.claude-dock-station/recents.json` (só o observado — sem crawl), limitado às
  50 janelas mais recentes.
- **Quando o nome de um projeto muda** — ao declarar um container, ou num worktree
  /submodule depois desta versão — uma pasta já listada pode aparecer **duas
  vezes**: a entrada antiga (nome anterior) e a nova. A antiga continua
  funcionando, mas nunca mais é atualizada, e **não some sozinha**: o corte por
  idade só age acima de 50 entradas, e a lista das Configurações não tem limite.
  Se incomodar, remova no **✕** da seção Recentes.
- **Gerenciar**: nas Configurações, a seção **Recentes** lista tudo com um **✕**
  por item e **Limpar todos** — só esquece do launcher, **não apaga** o histórico.
- O `code` é resolvido do bundle do app host, então não precisa do `code` no PATH.
- As vistas na tela (painel/mosaico/barra) mostram só sessões **vivas**; o
  histórico fica no menu. Reabrir abre a pasta; retomar o Claude (`claude -r`)
  dentro dela ainda é manual.

## Ônus / requisitos

- **Permissões fortes ao Hammerspoon**: **Acessibilidade** (pra enumerar/focar
  janelas) e **Gravação de Tela** (pra tirar a miniatura). Sem elas o card
  ainda aparece (o status vem do hook), só que sem miniatura.
- **Popup periódico de gravação de tela do macOS Sequoia** — o sistema
  reconfirma a permissão de tempos em tempos. O popup pode reaparecer sempre
  que as **miniaturas** estiverem ligadas: o motor tira snapshot das janelas
  a cada intervalo com qualquer casca ativa (inclusive o menu bar, que na
  config default já roda o loop de captura). Desligar miniaturas no painel de
  configurações elimina isso — o dock vira **status-only** e a permissão de
  Gravação de Tela deixa de ser necessária.
- **Hooks rodam em toda sessão do Claude Code** (`SessionStart`,
  `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop`,
  `SessionEnd`). O `PostToolUse` não é só mais um nome na lista: é ele que
  fecha o ciclo aberto pelo `PreToolUse`, resetando o evento quando a
  ferramenta termina. Sem ele, uma sessão só de pensar (sem ferramenta presa)
  correria o risco de ser mal-classificada como "precisa de você" depois de
  `needs_after_secs`. São fire-and-forget: rápidos, não-bloqueantes, sempre
  saem com `exit 0` mesmo se algo falhar (ver `hooks/emit.sh`).
- **Custo financeiro: zero.** Não chama a API do Claude — só lê e escreve
  arquivos locais em `~/.claude-dock-station/`.
- Processo Hammerspoon fica sempre rodando em segundo plano (~30-50MB).
- Cola frágil por natureza: o match de janela depende do título do VS Code
  conter o nome da pasta do projeto, e da API de hooks do Claude Code não mudar.

## Instalação

```bash
bash install.sh
```

> **Antes de rodar:** o `install.sh` não mexe só em config — se faltarem no seu
> Mac, ele instala `jq`, `lua` e o **app Hammerspoon** via Homebrew (`brew install
> --cask hammerspoon`). Também mescla os hooks no seu `~/.claude/settings.json`
> (com backup antes, `settings.json.bak.<timestamp>`, sem remover hook que já
> exista) e adiciona uma linha `dofile(...)` no seu `~/.hammerspoon/init.lua` — merge
> idempotente, dá pra rodar de novo à vontade. `bash uninstall.sh` desfaz essas duas
> edições de arquivo, mas **não** desinstala os pacotes do Homebrew nem apaga
> `~/.claude-dock-station/` (preservado de propósito).

O script:

1. Instala as dependências que faltarem via `brew` (`jq`, `lua`,
   `hammerspoon`).
2. Cria `~/.claude-dock-station/` (com `state/` e `config.json` default, só
   se ainda não existir).
3. Faz backup de `~/.claude/settings.json` (`settings.json.bak.<timestamp>`)
   e mescla os 7 hooks do Claude Dock Station nele, sem remover hooks que já
   existam ali — o merge é idempotente, pode rodar `install.sh` de novo à vontade.
4. Adiciona uma linha `dofile(...)` em `~/.hammerspoon/init.lua`, entre
   marcadores `-- >>> CLAUDE-DOCK-STATION >>>` / `-- <<< ... <<<` (idempotente).

Depois de instalar:

1. **Conceda as duas permissões ao Hammerspoon** em Ajustes do Sistema →
   Privacidade e Segurança:
   - **Acessibilidade**
   - **Gravação de Tela** — pode abrir direto pela URL que o próprio app usa:
     `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`
     (o botão "Abrir permissões" no painel de configurações faz isso por você).
2. Abra o **Hammerspoon** e recarregue a config (menu da barra → **Reload Config**).

A partir daí o ícone 🤖 aparece na barra de menu e o hotkey já está ativo.

## Uso

- **`Cmd+Shift+Space`** (default, configurável) — abre/fecha o overlay em
  tela cheia com todos os cards.
- **Ícone 🤖 N na barra de menu** — `N` é o total de sessões vivas; se
  alguma precisar de você, some `⚠️` com a contagem (ex: `🤖 3 ⚠️1`). O
  dropdown lista cada sessão e foca ao clicar.
- **Clique num card** (em qualquer casca) — foca a janela do VS Code daquela
  sessão.
- **"⚙️ Configurações"** (no menu bar ou nos botões das cascas) — abre o
  painel de admin, onde dá pra:
  - trocar o **atalho do overlay** (clique no campo, aperte a combinação
    desejada — captura via `hs.eventtap`, com timeout de segurança);
  - ligar/desligar **overlay** e **menu bar**; escolher a **Vista na tela**
    (nenhuma / painel fixo / mosaico / barra) e o **monitor** dela;
  - escolher o **canto** do painel fixo (ou a **borda** do mosaico/barra);
  - **desligar miniaturas** (vira status-only, elimina a necessidade de
    Gravação de Tela);
  - ajustar o **intervalo de atualização**, o **tema** (auto/dark/light) e o
    **app host** (default `Code`, pra quem usa outro editor);
  - ver o **diagnóstico de permissões** (✅/❌ Acessibilidade e Gravação de
    Tela) e os botões **Abrir permissões**, **Reinstalar hooks** e **Desinstalar**.
  - Salvar aplica tudo na hora, sem precisar reiniciar o Hammerspoon.

## Desinstalar

```bash
bash uninstall.sh
```

Remove o bloco de hooks do `~/.claude/settings.json` (com backup antes) e a
linha de load do `~/.hammerspoon/init.lua`. **Não apaga** `~/.claude-dock-station/`
(state e config ficam preservados, caso você reinstale depois).

## Sessões remotas (SSH)

O motor Hammerspoon roda só localmente, mas consegue puxar (via SSH, em
polling) o estado de sessões do Claude Code que estão rodando em **outras
máquinas**, e juntá-las no mesmo deck das sessões locais — cada card remoto
mostra o host (`☁ <nome>`) junto do detalhe/idade, do jeito já descrito nas
cascas acima.

**Vem desligado por padrão**: `remotes` nasce vazio (`[]`). Nenhum default
deste projeto aponta pra uma máquina específica — quem quiser sessões
remotas escolhe e configura o próprio host.

Pra ligar (repita para cada host):

1. `bash install-remote.sh <ssh-host>` (ex: `bash install-remote.sh my-vps`).
   O script cria `~/.claude-dock-station/{hooks,state}` no host remoto via
   `ssh`, copia `hooks/emit.sh` pra lá via `scp` e mescla os mesmos 7 hooks
   no `~/.claude/settings.json` **do remoto** — com backup antes, merge
   idempotente, igual ao `install.sh` local. Não instala Hammerspoon nem Lua
   lá: só os hooks, que são scripts de shell.
   - **Precisa de `jq` já instalado no host remoto.** O script confere isso
     e sai com `ERRO: jq ausente no host remoto` se faltar — diferente do
     `install.sh` local, ele não tenta instalar nada lá.
2. Adicione o host em `remotes`, no `~/.claude-dock-station/config.json`
   **local** (a chave não vem no `config.json` default gerado pelo
   `install.sh` — precisa criar):

   ```json
   { "remotes": ["my-vps"], "remote_interval_secs": 3 }
   ```

   `remote_interval_secs` (default `3`) é de quanto em quanto tempo o motor
   local puxa o estado de cada host via SSH — mais devagar que o polling
   local (`interval_secs`, default `1`) porque depende da rede. A conexão
   usa `ControlMaster`/`ControlPersist`, então só a primeira chamada paga o
   handshake do SSH.

**Atenção:** uma sessão que já estava rodando no host remoto antes do
`install-remote.sh` só passa a emitir estado a partir do **próximo evento**
dela (próximo prompt, ferramenta etc.) — não é retroativo.

Pra desligar um host: `bash uninstall-remote.sh <ssh-host>` remove só os
hooks do `~/.claude/settings.json` do remoto (com backup antes); a pasta
`~/.claude-dock-station/` de lá — incluindo o `emit.sh` copiado e o state —
fica preservada. Tire também o host da lista `remotes` no config local: o
script remoto não mexe nele.

## Como funciona / arquitetura

Cada evento de hook do Claude Code roda `hooks/emit.sh`, que escreve
`~/.claude-dock-station/state/<session_id>.json` com o estado atual da
sessão. O motor Hammerspoon (`hammerspoon/claude-dock-station.lua`) faz
polling desses arquivos a cada `interval_secs`, casa cada sessão com sua
janela do VS Code pelo nome da pasta (`cwd`), tira a miniatura (se
miniaturas estiverem ligadas) e monta a lista ordenada de cards, entregando
para a casca ativa via `hammerspoon/ui/grid.html`. Toda a lógica pura de
estado/ordenação/match (sem depender do runtime `hs.*`) vive em
`hammerspoon/core.lua`, que roda sob o `lua` padrão e é coberta pelos testes
unitários.

### Como o nome do projeto é decidido

O `emit.sh` roda **na máquina dona do `cwd`** (inclusive nos hosts remotos, via
`install-remote.sh`), então ele consegue perguntar coisas que o motor local só
poderia adivinhar. Além do estado, ele emite:

- **`root`** — `git rev-parse --show-toplevel`, ou `""` quando não há repo. Corta
  o ruído de subpasta que nenhuma lista de nomes daria conta: sem ele,
  `…/dash/supabase/functions` se rotula `functions`. **`root: ""` não significa
  "não é projeto"** — vários projetos reais não são repos git.
- **`home`** — o `$HOME` da máquina dona do `cwd`. Marca o que nunca é uma janela
  de projeto: a própria home e o cache do Claude em `~/.claude`.

O nome do card vem de até três sinais, que **competem pela profundidade no
`cwd`** — não é uma cadeia de prioridade, vence quem tiver o nome no segmento
mais fundo:

- o **container** declarado em `project_containers` (abaixo);
- a **raiz do git** (`root`, acima) — vira nome pelo primeiro segmento
  não-genérico dela, e não o `basename`: uma raiz de repo pode ser a própria
  pasta de ambiente, ex. `/opt/clients/acme/production` → `acme`;
- a **pasta que a janela do VS Code mostra** — o segmento do `cwd` que casou
  com o título da janela.

É essa competição por profundidade que faz um worktree ganhar nome próprio de
graça: a raiz do seu próprio git fica mais funda no `cwd` do que um container
declarado acima dele, então normalmente ninguém precisa declarar `.../worktrees`.
A mesma regra vale pra qualquer repo aninhado dentro de outro — submodule, repo
vendorizado —, então uma sessão dentro dele é nomeada pelo repo aninhado, não
pelo projeto pai.

**Com uma ressalva:** o nome tirado do `root` pula segmentos genéricos
(`main`, `staging`, `production`, `worktrees`…). Se a pasta do worktree se
chama justamente `main`, o `root` pula ela e cai num ancestral —
`/opt/apps/webapp/worktrees/main` vira `webapp`. É exatamente aí que declarar
`/opt/apps/webapp/worktrees` como container resolve: o filho direto é usado
como está, sem filtro de genérico, então o card volta a se chamar `main`.

`project_containers` (default `[]`) lista pastas cujos **filhos diretos** são
projetos — a pasta declarada em si nunca vira nome de card, e containers podem
se aninhar, valendo sempre o mais fundo. Existe pra um caso que nem `root` nem
a janela resolvem sozinhos: uma pasta de cliente com vários projetos dentro,
aberta como **uma única janela** no VS Code — sem o container, toda sessão ali
herdaria o nome do cliente.

Nenhum container vem configurado por padrão: `project_containers` nasce vazio
(`[]`), do mesmo jeito que `remotes` — a chave também não vem no `config.json`
default gerado pelo `install.sh`, então quem tem uma pasta assim declara a
própria:

```json
{ "project_containers": ["/opt/clients", "/opt/clients/<cliente>/sites"] }
```

Sem nenhum dos três sinais casando um segmento do `cwd`, o card cai no primeiro
segmento não-genérico do `root`, senão na heurística de segmentos sobre o
próprio `cwd`. Campos ausentes = hook antigo → comportamento anterior, sem
regressão.

## Testes

```bash
lua tests/core_spec.lua && bash tests/test_emit.sh && bash tests/test_install.sh
```
