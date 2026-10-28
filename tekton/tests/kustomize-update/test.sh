#!/bin/sh
# Testa o step `update-and-push` da Task kustomize-update com repos git descartaveis.
#
# Corre o script de tekton/tasks/kustomize-update.yaml tal e qual, num Alpine 3.19 (o mesmo BusyBox,
# git e kustomize da imagem da Task), contra uma "app" com dois commits e um "infra" onde um
# escritor concorrente e simulado. Nao toca no cluster: so usa `apk add` e o download do kustomize
# que o proprio script faz.
#
# Da raiz do repo, no Git Bash do Windows:
#   MSYS_NO_PATHCONV=1 podman run --rm -v "$(pwd -W):/repo:ro" docker.io/library/alpine:3.19 sh /repo/tekton/tests/kustomize-update/test.sh
# Em Linux ou macOS, `-v "$PWD:/repo:ro"` e sem a variavel.
#
# TASK_SCRIPT=/caminho/script.sh testa outro script em vez do que esta no YAML (por exemplo o antigo,
# para ver os testes de corrida e de recuo falharem). VERBOSE=1 mostra o log do step de cada caso.
set -eu

case "$0" in /*) SELF=$0 ;; *) SELF=$PWD/$0 ;; esac
REPO=${REPO:-/repo}
ROOT=/tmp/kutest
REAL_GIT=/usr/bin/git
OVERLAY=apps/getwalletly/k8s/overlays/production
API=harbor.local/colorforge/getwalletly-api

digest() { printf 'sha256:%064d' "$1"; }

kustomization() {
  cat <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: getwalletly

resources:
- ../../base

# Written by the pipelines (kustomize-update) after an image passes every gate
images:
- digest: $(digest 1)
  name: harbor.local/colorforge/getwalletly-api
  newName: harbor.local/colorforge/getwalletly-api
- digest: $(digest 2)
  name: harbor.local/colorforge/getwalletly-frontend
  newName: harbor.local/colorforge/getwalletly-frontend
- digest: $(digest 3)
  name: harbor.local/colorforge/getwalletly-mcp-server
  newName: harbor.local/colorforge/getwalletly-mcp-server
EOF
}

# --- Acoes dos escritores concorrentes ---------------------------------------------------------
# O wrapper do git chama `sh test.sh act` antes de cada `git push` do script. ON_PUSH lista o que
# fazer e em que push: "1:infra-edit,1:app-advance" ou "*:infra-append" (todos os pushes).

infra_start() { # poe-se no clone de trabalho do infra, em cima de main (corre dentro de um subshell)
  cd "${T}/infra-work"
  git pull -q --rebase origin main
}

act_infra_edit() { # outro pipeline escreve em main com a edicao COMP_SED
  ( infra_start
    sed -i "${COMP_SED}" "${OVERLAY}/kustomization.yaml"
    git commit -q -am "chore(deploy): concorrente ${PUSH_N}"
    git push -q origin HEAD:main )
}

act_infra_append() { # outro escritor acrescenta uma linha no fim de main, em cada push
  ( infra_start
    echo "# concorrente ${PUSH_N}" >> "${OVERLAY}/kustomization.yaml"
    git commit -q -am "chore: concorrente ${PUSH_N}"
    git push -q origin HEAD:main )
}

act_infra_side() { # deixa o commit concorrente fora de main, para o hook pre-receive o por la a meio do push
  ( infra_start
    sed -i "${COMP_SED}" "${OVERLAY}/kustomization.yaml"
    git commit -q -am "chore(deploy): concorrente ${PUSH_N}"
    git push -q origin HEAD:refs/heads/competitor
    git rev-parse HEAD > "${T}/infra.git/competitor-sha"
    git reset -q --hard origin/main )
}

act_app_advance() { # chega um commit novo a main da app
  ( cd "${T}/app-work"
    echo tres > f.txt
    git commit -q -am "feat: tres"
    git push -q origin HEAD:main )
}

if [ "${1:-}" = "act" ]; then
  set -f
  for item in $(echo "${ON_PUSH:-}" | tr ',' ' '); do
    n=${item%%:*}
    action=${item#*:}
    if [ "${n}" = "*" ] || [ "${n}" = "${PUSH_N}" ]; then
      "act_$(echo "${action}" | tr '-' '_')"
    fi
  done
  exit 0
fi

# --- Montagem dos casos -------------------------------------------------------------------------

PASS=0
FAIL=0
CASE_N=0
CASE_FAILED=0

t_ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
t_fail() { FAIL=$((FAIL + 1)); CASE_FAILED=1; echo "  FAIL  $1"; }
eq() { if [ "$1" = "$2" ]; then t_ok "$3"; else t_fail "$3 (esperado '$1', obtido '$2')"; fi; }
ne() { if [ "$1" != "$2" ]; then t_ok "$3"; else t_fail "$3 (nao devia ser '$2')"; fi; }
has() { if grep -qF -- "$2" "$1"; then t_ok "$3"; else t_fail "$3 (falta '$2' em $(basename "$1"))"; fi; }
hasnt() { if grep -qF -- "$2" "$1"; then t_fail "$3 (encontrei '$2' em $(basename "$1"))"; else t_ok "$3"; fi; }

infra_head() { git -C "${T}/infra.git" rev-parse main; }
infra_file() { git -C "${T}/infra.git" show "main:${OVERLAY}/kustomization.yaml"; }

begin() { # $1 = descricao; prepara a pasta do caso e o wrapper do git
  CASE_N=$((CASE_N + 1))
  CASE_FAILED=0
  T="${ROOT}/caso${CASE_N}"
  rm -rf "${T}"
  mkdir -p "${T}/bin" "${T}/home"
  echo ""
  echo "[${CASE_N}] $1"
  cat > "${T}/bin/git" <<EOF
#!/bin/sh
if [ "\${1:-}" = push ]; then
  n=\$(cat "${T}/push.count"); n=\$((n + 1)); echo "\$n" > "${T}/push.count"
  PATH="\${REAL_PATH}" PUSH_N="\$n" sh "${SELF}" act
fi
exec ${REAL_GIT} "\$@"
EOF
  chmod +x "${T}/bin/git"
  export T OVERLAY ON_PUSH="" COMP_SED=""
}

race() { # $1 = o que os concorrentes fazem e em que push (ver ON_PUSH), $2 = edicao sed do concorrente
  ON_PUSH=$1
  COMP_SED=$2
  export ON_PUSH COMP_SED
}

end_case() { # com VERBOSE=1 mostra sempre o log do step; sem isso, so quando o caso falha
  if [ "${CASE_FAILED}" = 1 ] || [ -n "${VERBOSE:-}" ]; then
    echo "      --- log do step ---"
    sed 's/^/      | /' "${T}/out.log" | tail -60
    echo "      shallow: $(git -C "${T}/ws/manifest-repo" rev-parse --is-shallow-repository 2>/dev/null || echo n/a)"
  fi
}

new_work_clone() { # $1 = bare, $2 = pasta
  git clone -q "file://$1" "$2" 2>/dev/null
  git -C "$2" config user.name concorrente
  git -C "$2" config user.email concorrente@test
}

setup_app() { # app com dois commits em main (ou no ramo $1); define APP_OLD e APP_NEW
  branch=${1:-main}
  git init -q --bare -b "${branch}" "${T}/app.git"
  new_work_clone "${T}/app.git" "${T}/app-work"
  ( cd "${T}/app-work"
    echo um > f.txt
    git add f.txt
    git commit -q -m "feat: um"
    echo dois > f.txt
    git commit -q -am "feat: dois"
    git push -q origin "HEAD:refs/heads/${branch}" )
  APP_OLD=$(git -C "${T}/app-work" rev-parse HEAD~1)
  APP_NEW=$(git -C "${T}/app-work" rev-parse HEAD)
}

setup_infra() {
  git init -q --bare -b main "${T}/infra.git"
  new_work_clone "${T}/infra.git" "${T}/infra-work"
  mkdir -p "${T}/infra-work/${OVERLAY}"
  kustomization > "${T}/infra-work/${OVERLAY}/kustomization.yaml"
  ( cd "${T}/infra-work"
    git add .
    git commit -q -m "chore: base"
    git push -q origin HEAD:main )
}

setup_ws() { # $1 = commit; o que a task git-clone faz com um SHA: clone e checkout
  git clone -q "file://${T}/app.git" "${T}/ws" 2>/dev/null
  git -C "${T}/ws" checkout -q "$1"
}

# O que corre o step: as variaveis de ambiente da Task, o workspace como cwd, o wrapper do git.
run_task() { # $1 = tag, $2 = digest ("" para escrever pela tag)
  mkdir -p /tekton/results "${T}/ws"
  rm -f /tekton/results/commit-sha
  echo 0 > "${T}/push.count"
  RC=0
  ( cd "${T}/ws"
    export HOME="${T}/home" GIT_URL="file://${T}/infra.git" GIT_BRANCH=main OVERLAY_PATH="${OVERLAY}" \
      IMAGE_NAME="${API}" NEW_TAG="$1" NEW_DIGEST="$2" GIT_USER_NAME="Tekton Pipeline" \
      GIT_USER_EMAIL=tekton@test WORKSPACE_SOURCE_PATH="${T}/ws" WORKSPACE_SSH_CREDENTIALS_BOUND=false \
      WORKSPACE_SSH_CREDENTIALS_PATH="" WORKSPACE_BASIC_AUTH_BOUND=false WORKSPACE_BASIC_AUTH_PATH="" \
      PUSH_RETRY_DELAY=0 REAL_PATH="${PATH}" PATH="${T}/bin:${PATH}"
    sh "${SCRIPT}" ) > "${T}/out.log" 2>&1 || RC=$?
  RESULT=$(cat /tekton/results/commit-sha 2>/dev/null || true)
  PUSHES=$(cat "${T}/push.count")
}

reject_pushes_hook() { # pre-receive que recusa sempre, como uma branch protegida
  cat > "${T}/infra.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
echo "error: GH006: Protected branch update failed for refs/heads/main." >&2
exit 1
EOF
  chmod +x "${T}/infra.git/hooks/pre-receive"
}

lose_the_lock_hook() { # pre-receive que poe o commit concorrente em main enquanto o push e recebido
  cat > "${T}/infra.git/hooks/pre-receive" <<EOF
#!/bin/sh
touches_main=""
while read old new ref; do [ "\$ref" = refs/heads/main ] && touches_main=1; done
[ -n "\$touches_main" ] || exit 0
[ -e "${T}/infra.git/raced" ] && exit 0
touch "${T}/infra.git/raced"
unset GIT_QUARANTINE_PATH GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
${REAL_GIT} --git-dir="${T}/infra.git" update-ref refs/heads/main "\$(cat "${T}/infra.git/competitor-sha")"
EOF
  chmod +x "${T}/infra.git/hooks/pre-receive"
}

# --- Preparacao ---------------------------------------------------------------------------------

apk add --no-cache git curl bash > /dev/null
mkdir -p "${ROOT}"

if [ -n "${TASK_SCRIPT:-}" ]; then
  SCRIPT=${TASK_SCRIPT}
else
  # O script do step: o bloco `script: |` do YAML, sem a indentacao (e sem CR, num checkout de Windows).
  SCRIPT="${ROOT}/task-script.sh"
  tr -d '\r' < "${REPO}/tekton/tasks/kustomize-update.yaml" | awk '
    !found && /^ +script: \|$/ { match($0, /^ +/); base = RLENGTH + 2; found = 1; next }
    found {
      if ($0 ~ /^ *$/) { print ""; next }
      match($0, /^ */)
      if (RLENGTH < base) exit
      print substr($0, base + 1)
    }' > "${SCRIPT}"
fi
echo "Script sob teste: ${SCRIPT} ($(wc -l < "${SCRIPT}") linhas)"

echo ""
echo "[0] o script e valido e nao usa substituicoes do Tekton"
if sh -n "${SCRIPT}"; then t_ok "sh -n aceita o script"; else t_fail "sh -n recusa o script"; fi
if grep -nE '\$\((params|workspaces|results|context|steps|tasks)\.' "${SCRIPT}" > /dev/null; then
  t_fail "o script tem \$(params./workspaces./...): o Tekton substitui-os antes de correr"
else
  t_ok "tudo o que vem da Task entra por variaveis de ambiente"
fi

# --- Casos --------------------------------------------------------------------------------------

begin "normal: o commit do run e o HEAD da app, escreve uma vez"
setup_app; setup_infra; setup_ws "${APP_NEW}"
before=$(infra_head)
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 1 "${PUSHES}" "um push"
has "${T}/out.log" "HEAD da app confirmado: ${APP_NEW}" "a guarda confirma o HEAD"
eq "$(infra_head)" "${RESULT}" "o resultado commit-sha e o commit novo do infra"
eq "$(printf '1\t1\t%s' "${OVERLAY}/kustomization.yaml")" "$(git -C "${T}/infra.git" diff --numstat "${before}" main)" "muda uma linha, so a da imagem"
has "${T}/out.log" "Updated ${API} to digest $(digest 11)" "escreve o digest"
eq "Tekton Pipeline <tekton@test>" "$(git -C "${T}/infra.git" log -1 --format='%an <%ae>' main)" "autor do commit"
eq "chore(deploy): update ${API} to ${APP_NEW}

Automated update by Tekton Pipeline

Image: ${API}
Tag: ${APP_NEW}
Digest: $(digest 11)" "$(git -C "${T}/infra.git" log -1 --format=%B main)" "mensagem do commit igual a de sempre"
end_case

begin "normal sem digest: escreve pela tag"
setup_app; setup_infra; setup_ws "${APP_NEW}"
run_task "${APP_NEW}" ""
eq 0 "${RC}" "o step termina com sucesso"
eq 1 "${PUSHES}" "um push"
infra_file > "${T}/main.yaml"
has "${T}/main.yaml" "newTag: ${APP_NEW}" "a imagem fica com a tag do commit"
end_case

begin "sem mudancas: o digest ja la esta, nao ha commit nem push"
setup_app; setup_infra; setup_ws "${APP_NEW}"
run_task "${APP_NEW}" "$(digest 11)"
before=$(infra_head)
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 0 "${PUSHES}" "nenhum push"
eq "no-change" "${RESULT}" "resultado no-change"
eq "${before}" "$(infra_head)" "o infra fica como estava"
end_case

begin "recuo: o run e de um commit antigo e main da app ja avancou, salta"
setup_app; setup_infra; setup_ws "${APP_OLD}"
before=$(infra_head)
run_task "${APP_OLD}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 0 "${PUSHES}" "nenhum push"
eq "skipped-stale" "${RESULT}" "resultado skipped-stale"
eq "${before}" "$(infra_head)" "o infra nao foi tocado"
has "${T}/out.log" "SALTADO" "mensagem de salto"
has "${T}/out.log" "construiu ${APP_OLD}" "diz que commit o run construiu"
has "${T}/out.log" "ja e ${APP_NEW}" "diz qual e o HEAD da app"
end_case

begin "corrida (non-fast-forward): dois commits de outros runs entre o clone e o push, repete e passa"
setup_app; setup_infra; setup_ws "${APP_NEW}"
race "1:infra-edit,1:infra-append" "s|$(digest 2)|$(digest 22)|"
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 2 "${PUSHES}" "dois pushes: o que perdeu e o que repetiu"
has "${T}/out.log" "Corrida no push (tentativa 1 de 5)" "avisa da corrida"
infra_file > "${T}/main.yaml"
has "${T}/main.yaml" "$(digest 11)" "a imagem deste run esta no infra"
has "${T}/main.yaml" "$(digest 22)" "a imagem do outro run tambem: ninguem perdeu nada"
hasnt "${T}/main.yaml" "$(digest 2)" "nem sobra a imagem antiga do outro"
has "${T}/main.yaml" "# concorrente 1" "nem a segunda escrita do outro"
eq 2 "$(git -C "${T}/infra.git" log --format=%s main | grep -c concorrente)" "os dois commits do outro continuam no historico"
eq "$(infra_head)" "${RESULT}" "o resultado commit-sha e o commit que ficou em main"
end_case

begin "corrida (cannot lock ref): o ref muda a meio do push, repete e passa"
setup_app; setup_infra; setup_ws "${APP_NEW}"
lose_the_lock_hook
race "1:infra-side" "s|$(digest 2)|$(digest 22)|"
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 2 "${PUSHES}" "dois pushes"
has "${T}/out.log" "cannot lock ref" "o erro foi mesmo o cannot lock ref do git"
has "${T}/out.log" "Corrida no push" "tratado como corrida"
infra_file > "${T}/main.yaml"
has "${T}/main.yaml" "$(digest 11)" "a imagem deste run esta no infra"
has "${T}/main.yaml" "$(digest 22)" "a do concorrente tambem"
end_case

begin "corrida com conflito: o outro mexeu na mesma imagem, refaz o commit e a imagem deste run fica"
setup_app; setup_infra; setup_ws "${APP_NEW}"
race "1:infra-edit" "s|$(digest 1)|$(digest 99)|"
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 2 "${PUSHES}" "dois pushes"
has "${T}/out.log" "deu conflito" "o pull --rebase deu conflito e o script refez o commit"
infra_file > "${T}/main.yaml"
has "${T}/main.yaml" "$(digest 11)" "a imagem deste run esta no infra"
hasnt "${T}/main.yaml" "$(digest 99)" "a do concorrente (mesma imagem) foi substituida"
if [ -d "${T}/ws/manifest-repo/.git/rebase-merge" ]; then t_fail "ficou um rebase a meio"; else t_ok "nao ficou um rebase a meio"; fi
end_case

begin "corrida em que o outro run escreveu a mesma imagem: nada a empurrar, termina com sucesso"
setup_app; setup_infra; setup_ws "${APP_NEW}"
race "1:infra-edit" "s|$(digest 1)|$(digest 11)|"
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 2 "${PUSHES}" "dois pushes: o segundo ja nao tem nada a enviar"
has "${T}/out.log" "Everything up-to-date" "o git diz que nao ha nada a enviar"
eq "$(infra_head)" "${RESULT}" "o resultado commit-sha e o commit que ficou em main"
eq 1 "$(infra_file | grep -c "$(digest 11)")" "a imagem aparece uma so vez"

begin "corrida e a app avanca entretanto: antes de repetir volta a confirmar e salta"
setup_app; setup_infra; setup_ws "${APP_NEW}"
race "1:infra-edit,1:app-advance" "s|$(digest 2)|$(digest 22)|"
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 1 "${PUSHES}" "so o primeiro push: o segundo nao chega a acontecer"
has "${T}/out.log" "Corrida no push" "viu a corrida"
has "${T}/out.log" "SALTADO" "e saltou na reconfirmacao"
eq "skipped-stale" "${RESULT}" "resultado skipped-stale"
infra_file > "${T}/main.yaml"
hasnt "${T}/main.yaml" "$(digest 11)" "a imagem antiga nao foi escrita"
has "${T}/main.yaml" "$(digest 22)" "fica o que o outro run escreveu"
end_case

begin "corrida sem fim: perde as 5 tentativas, falha com mensagem clara"
setup_app; setup_infra; setup_ws "${APP_NEW}"
export ON_PUSH="*:infra-append"
run_task "${APP_NEW}" "$(digest 11)"
ne 0 "${RC}" "o step falha"
eq 5 "${PUSHES}" "cinco pushes, nem mais nem menos"
has "${T}/out.log" "desisto" "diz que desistiu"
infra_file > "${T}/main.yaml"
hasnt "${T}/main.yaml" "$(digest 11)" "a imagem nao chegou ao infra"
end_case

begin "erro de push que nao e corrida: falha logo, sem repetir"
setup_app; setup_infra; setup_ws "${APP_NEW}"
reject_pushes_hook
run_task "${APP_NEW}" "$(digest 11)"
ne 0 "${RC}" "o step falha"
eq 1 "${PUSHES}" "um so push"
has "${T}/out.log" "GH006" "mostra o erro do servidor"
has "${T}/out.log" "nao foi por corrida" "diz que nao e corrida"
hasnt "${T}/out.log" "Corrida no push" "nao trata como corrida"
end_case

begin "sem checkout da app no workspace: avisa e escreve como antes"
setup_app; setup_infra; mkdir -p "${T}/ws"
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 1 "${PUSHES}" "um push"
has "${T}/out.log" "nao ha checkout da app" "avisa que nao confirmou"
end_case

begin "a app nao tem main: avisa e escreve como antes"
setup_app trunk; setup_infra; setup_ws "${APP_NEW}"
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 1 "${PUSHES}" "um push"
has "${T}/out.log" "main nao existe" "avisa que nao confirmou"
end_case

begin "a app nao responde, com credenciais no URL: avisa, escreve e nao mostra a palavra-passe"
setup_app; setup_infra; setup_ws "${APP_NEW}"
git -C "${T}/ws" remote set-url origin "https://utilizador:s3cr3t@127.0.0.1:1/app.git"
run_task "${APP_NEW}" "$(digest 11)"
eq 0 "${RC}" "o step termina com sucesso"
eq 1 "${PUSHES}" "um push"
has "${T}/out.log" "nao respondeu" "avisa que nao confirmou"
has "${T}/out.log" "unable to access" "mostra o erro do git, para se perceber porque nao respondeu"
hasnt "${T}/out.log" "s3cr3t" "a palavra-passe nao aparece no log"
end_case

echo ""
echo "== ${PASS} verificacoes ok, ${FAIL} falharam =="
[ "${FAIL}" = 0 ]
