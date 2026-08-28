from pathlib import Path


def replace_once(path, old, new):
    p = Path(path)
    text = p.read_text(encoding='utf-8')
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f'{path}: expected 1 occurrence, found {count}: {old[:80]!r}')
    p.write_text(text.replace(old, new, 1), encoding='utf-8', newline='\n')

# Remove obsolete gates: source presence is now inferred from correlation results.
replace_once(
    'DeviceLifecycle.Config.psd1',
    "    # Conservative correlation. A missing or duplicated cloud record is sent\n"
    "    # to manual review instead of being changed.\n"
    "    RequireEntraMatch = $true\n"
    "    RequireIntuneMatch = $true\n"
    "    ExcludeAutopilotDevices = $true",
    "    # Correlation policy: a missing Entra/Intune record is treated as unavailable\n"
    "    # evidence. Ambiguous or inconsistent correlated records still require manual\n"
    "    # review, and timestamps remain required for every source that is present.\n"
    "    ExcludeAutopilotDevices = $true",
)

# English README.
replace_once(
    'README.md',
    "- Correlates AD, Entra ID, and Intune records using stable identifiers rather than computer names alone.",
    "- Correlates AD, Entra ID, and Intune records using stable identifiers rather than computer names alone. Missing cloud records are treated as unavailable evidence, while existing sources still contribute their activity timestamps.",
)
replace_once('README.md', '    Attention --> ManualReview: missing or ambiguous identity', '    Attention --> ManualReview: ambiguous or inconsistent identity')
replace_once(
    'README.md',
    '- Missing, duplicated, or ambiguous cloud matches are not modified.',
    '- Missing cloud records are treated as unavailable evidence; duplicated, ambiguous, or inconsistent matches are not modified.',
)
replace_once('README.md', "- `MissingEntraMatch`\n- `MissingIntuneMatch`\n", '')

# Portuguese README.
replace_once(
    'README.pt-BR.md',
    '- Correlação entre AD, Entra ID e Intune usando identificadores estáveis, não apenas o nome do computador.',
    '- Correlação entre AD, Entra ID e Intune usando identificadores estáveis, não apenas o nome do computador. Registros cloud ausentes são tratados como evidência indisponível, enquanto fontes existentes continuam contribuindo com seus timestamps de atividade.',
)
replace_once('README.pt-BR.md', '    Atencao --> RevisaoManual: identidade ausente ou ambígua', '    Atencao --> RevisaoManual: identidade ambígua ou inconsistente')
replace_once(
    'README.pt-BR.md',
    '- Correspondências ausentes, duplicadas ou ambíguas não são modificadas.',
    '- Registros cloud ausentes são tratados como evidência indisponível; correspondências duplicadas, ambíguas ou inconsistentes não são modificadas.',
)
replace_once('README.pt-BR.md', "- `MissingEntraMatch`\n- `MissingIntuneMatch`\n", '')

# Architecture docs.
replace_once(
    'docs/en/ARCHITECTURE.md',
    '3. The result must be unique and must satisfy the configured matching requirements.',
    '3. When a cloud record exists, the result must be unique and satisfy the identity-consistency checks. A missing cloud record is treated as unavailable evidence rather than a correlation failure.',
)
replace_once(
    'docs/en/ARCHITECTURE.md',
    'A missing or duplicated match is not silently guessed. It is classified for manual review.',
    'A missing cloud record is not guessed or synthesized; that source is omitted from the activity decision. Duplicated, ambiguous, or inconsistent matches are classified for manual review.',
)
replace_once(
    'docs/en/ARCHITECTURE.md',
    'Uncertainty results in `ManualReview`, not a destructive fallback. This includes missing matches, duplicate matches, missing activity timestamps, protected objects, and unsupported records.',
    'Uncertainty results in `ManualReview`, not a destructive fallback. This includes duplicate or inconsistent matches, missing activity timestamps for sources that exist, protected objects, and unsupported records. A source with no correlated record is treated as unavailable evidence and does not block lifecycle evaluation from the remaining sources.',
)

replace_once(
    'docs/pt-BR/ARCHITECTURE.md',
    '3. O resultado deve ser único e cumprir os requisitos configurados.',
    '3. Quando existe um registro cloud, o resultado deve ser único e cumprir as validações de consistência da identidade. A ausência de um registro cloud é tratada como evidência indisponível, não como falha de correlação.',
)
replace_once(
    'docs/pt-BR/ARCHITECTURE.md',
    'Uma correspondência ausente ou duplicada não é adivinhada. O registro é classificado para revisão manual.',
    'Um registro cloud ausente não é adivinhado nem sintetizado; essa fonte é omitida da decisão de atividade. Correspondências duplicadas, ambíguas ou inconsistentes são classificadas para revisão manual.',
)
replace_once(
    'docs/pt-BR/ARCHITECTURE.md',
    'Incerteza resulta em `ManualReview`, não em ação destrutiva. Isso inclui registros ausentes, duplicados, timestamps vazios, objetos protegidos e situações não suportadas.',
    'Incerteza resulta em `ManualReview`, não em ação destrutiva. Isso inclui correspondências duplicadas ou inconsistentes, timestamps ausentes em fontes que existem, objetos protegidos e situações não suportadas. Uma fonte sem registro correlacionado é tratada como evidência indisponível e não bloqueia a avaliação pelas demais fontes.',
)

replace_once(
    'CHANGELOG.md',
    '- Corrected and clarified the relationship between `DeviceLifecycle` and the separate `DeviceLifecycle-API` repository.',
    '- Corrected and clarified the relationship between `DeviceLifecycle` and the separate `DeviceLifecycle-API` repository.\n- Changed lifecycle correlation so missing Entra ID or Intune records are treated as unavailable evidence instead of forcing `ManualReview`; ambiguous/inconsistent matches and missing timestamps on existing records remain fail-closed.\n- Added activity-policy tests covering AD-only, partial-cloud, recent-cloud, warning, and missing-timestamp scenarios.',
)
