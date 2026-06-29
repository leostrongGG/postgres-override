# Contribuindo para o postgres-override

Obrigado por considerar contribuir! 🎉

## Como Contribuir

1. **Fork** o projeto
2. Crie uma **branch** para sua feature (`git checkout -b feature/MinhaFeature`)
3. **Commit** suas mudanças (`git commit -m 'Add: descrição da feature'`)
4. **Push** para a branch (`git push origin feature/MinhaFeature`)
5. Abra um **Pull Request**

## Padrões de Commit

Use prefixos claros:

- `Add:` nova funcionalidade
- `Fix:` correção de bug
- `Docs:` documentação
- `Refactor:` refatoração sem mudança de comportamento
- `Test:` adicionar testes

## Reportar Bugs

Ao reportar bugs, inclua:

- Versão do sistema operacional
- Versão do Docker e Docker Compose
- Saída completa do script (`postgres-override.sh`)
- Conteúdo do `docker-compose.override.yaml` existente (se houver)

## Sugestões de Features

Abra uma issue descrevendo:

- Problema que resolve
- Como funcionaria
- Exemplos de uso

## Testes

Antes de enviar PR:

1. Teste em ambiente não-produção
2. Valide que o merge preserva outros serviços no override
3. Confirme que os backups são gerados corretamente
4. Verifique a sintaxe do script com `bash -n postgres-override.sh`

## Dúvidas?

Abra uma issue ou discussion no GitHub!
