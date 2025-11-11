#!/usr/bin/env bash
set -Eeuo pipefail

cfg="${KBUILD_OUTPUT}/.config"

# cria config mínima se necessário
if [[ ! -f "$cfg" ]]; then
    echo "[kernel performance] criando config base (tinyconfig)"
    make O="${KBUILD_OUTPUT}" tinyconfig
fi

# scripts/config obrigatório
if ! command -v scripts/config >/dev/null 2>&1; then
    echo "[kernel performance] scripts/config indisponível"
else
    # Scheduler e Preemption
    scripts/config -e CONFIG_SCHED_MC
    scripts/config -e CONFIG_SCHED_SMT
    scripts/config -e CONFIG_PREEMPT
    scripts/config -e CONFIG_PREEMPT_BUILD
    scripts/config -e CONFIG_HZ_1000
    scripts/config -d CONFIG_HZ_300

    # I/O tuning
    scripts/config -e CONFIG_BFQ_GROUP_IOSCHED
    scripts/config -e CONFIG_BFQ_CGROUP_DEBUG

    # CPU freq
    scripts/config -e CONFIG_CPU_FREQ
    scripts/config -e CONFIG_CPU_FREQ_DEFAULT_GOV_PERFORMANCE
    scripts/config -e CONFIG_CPU_FREQ_GOV_PERFORMANCE
    scripts/config -d CONFIG_CPU_FREQ_GOV_POWERSAVE
    scripts/config -d CONFIG_CPU_FREQ_GOV_CONSERVATIVE

    # Networking
    scripts/config -e CONFIG_TCP_CONG_BBR
    scripts/config -e CONFIG_NET_SCH_FQ
    scripts/config -e CONFIG_NET_SCH_FQ_CODEL

    # Retorar desempenho
    scripts/config -e CONFIG_NO_HZ_FULL
    scripts/config -e CONFIG_HIGH_RES_TIMERS

fi

echo "[kernel performance] flags habilitadas"
