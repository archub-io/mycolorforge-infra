# O que está mesmo a correr

Estes ficheiros são um despejo dos objetos Tekton que o cluster usa hoje.

Não são a mesma coisa que `tekton/pipelines/`. Esses definem
`colorforge-backend-pipeline` e `colorforge-frontend-pipeline`; o que dispara
nos pushes é `mycolorforge-backend-pipeline` e `mycolorforge-frontend-pipeline`
— objetos diferentes, com 218 dias, que nunca estiveram no git.

Descobriu-se ao investigar por que o pipeline do backend nunca tinha corrido.
Três coisas o impediam e foram corrigidas por `kubectl patch`, ou seja, em
objetos que ninguém versionava:

- `sonar-credentials` estava opcional no pipeline e obrigatório na tarefa
  `sonarqube`, o que fazia o Tekton recusar o run à nascença;
- `go-cache` e `trivy-cache` eram PVC, e uma tarefa não pode ligar dois — o
  pipeline do frontend já os tinha como `emptyDir`, e é por isso que corria;
- o build usava Go 1.21 contra um `go.mod` que exige 1.25, e compilava `./...`
  para um único ficheiro em vez de `./cmd/server`.

Estão aqui para que as correções não se percam e para que a diferença entre o
que está escrito e o que corre deixe de ser invisível. O passo seguinte é
decidir qual dos dois conjuntos fica: o de `tekton/pipelines/`, que está
versionado e não é usado, ou este, que é usado e não estava.
