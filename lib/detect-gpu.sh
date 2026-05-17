#!/bin/bash
set -euo pipefail

# CachyOS on Omarchy - GPU detection library
#
# Vendor and NVIDIA generation detection by PCI device IDs.
# NEVER heuristically parses card name strings ("RTX", "GTX", etc.).
# When the device ID is unrecognised, detection MUST return "unknown" so the
# caller can abort the NVIDIA install path instead of guessing.
#
# Reference: nouveau.freedesktop.org/CodeNames.html

# detect_gpu_vendor
#
# Reads `lspci -nn` output from stdin when piped; otherwise runs `lspci -nn`
# itself. Filters PCI class codes 0300 (VGA), 0302 (3D), 0380 (Display) and
# looks at the vendor portion of the [VVVV:DDDD] tag.
#
# Vendor IDs: NVIDIA=10de, AMD=1002, Intel=8086.
#
# Output: nvidia | amd | intel | hybrid:<vendors> | unknown
#   Multi-vendor: nvidia first when present, remaining vendors alphabetical.
detect_gpu_vendor() {
    local input
    if [[ -t 0 ]]; then
        input="$(lspci -nn 2>/dev/null || true)"
    else
        input="$(cat)"
    fi

    local gpu_lines
    gpu_lines="$(printf '%s\n' "$input" | grep -Ei '\[(0300|0302|0380)\]' || true)"

    if [[ -z "$gpu_lines" ]]; then
        echo "unknown"
        return 0
    fi

    local has_nvidia=0
    local has_amd=0
    local has_intel=0
    local line

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ \[10de:[0-9a-fA-F]{4}\] ]]; then
            has_nvidia=1
        fi
        if [[ "$line" =~ \[1002:[0-9a-fA-F]{4}\] ]]; then
            has_amd=1
        fi
        if [[ "$line" =~ \[8086:[0-9a-fA-F]{4}\] ]]; then
            has_intel=1
        fi
    done <<<"$gpu_lines"

    local total=$((has_nvidia + has_amd + has_intel))

    if [[ $total -eq 0 ]]; then
        echo "unknown"
        return 0
    fi

    if [[ $total -eq 1 ]]; then
        if [[ $has_nvidia -eq 1 ]]; then
            echo "nvidia"
        elif [[ $has_amd -eq 1 ]]; then
            echo "amd"
        else
            echo "intel"
        fi
        return 0
    fi

    # Multi-vendor: nvidia first if present, then remaining alphabetical.
    local others=""
    if [[ $has_amd -eq 1 && $has_intel -eq 1 ]]; then
        others="amd,intel"
    elif [[ $has_amd -eq 1 ]]; then
        others="amd"
    elif [[ $has_intel -eq 1 ]]; then
        others="intel"
    fi

    if [[ $has_nvidia -eq 1 ]]; then
        echo "hybrid:nvidia,${others}"
    else
        echo "hybrid:${others}"
    fi
}

# detect_nvidia_gen DEVICE_ID
#
# Maps a 4-hex-digit PCI device ID (lowercase hex) to NVIDIA generation.
# Uses an explicit `case` statement over device ID ranges, NEVER heuristics
# over the card name string.
#
# Output: blackwell | ada | ampere | turing | volta | pascal |
#         maxwell | kepler | fermi | unknown
#
# Unknown means "do not install any NVIDIA driver"; callers MUST honour this.
detect_nvidia_gen() {
    local dev_id="${1:-}"
    dev_id="${dev_id,,}"

    case "$dev_id" in
        # Blackwell (RTX 50xx): 2b00-2bff
        2b??)
            echo "blackwell"
            ;;
        # Ada Lovelace (RTX 40xx): 2600-27ff
        # (e.g. 2684=RTX 4090, 2704=RTX 4080, 2782=RTX 4070)
        2[6-7]??)
            echo "ada"
            ;;
        # Ampere (RTX 30xx): 2200-25ff
        # (e.g. 2204=RTX 3090, 2208=RTX 3080, 2484=RTX 3070, 2503=RTX 3060)
        2[2-5]??)
            echo "ampere"
            ;;
        # Turing (RTX 20xx + GTX 16xx): 1e00-1fff
        # (e.g. 1e04=RTX 2080 Ti, 1f02=RTX 2070, 1f06=RTX 2060)
        1[ef]??)
            echo "turing"
            ;;
        # Volta (Titan V, V100): 1d00-1dff
        1d??)
            echo "volta"
            ;;
        # Pascal (GTX 10xx): 1b00-1c9f
        # (e.g. 1b06=GTX 1080 Ti, 1b80=GTX 1080, 1c02=GTX 1060 3GB)
        1b??|1c[0-9]?)
            echo "pascal"
            ;;
        # Maxwell (GTX 9xx + 750): 1380-17ff
        # (e.g. 13c0=GTX 980M, 13c2=GTX 970, 17c8=GTX 980)
        13[89a-f]?|1[4-7]??)
            echo "maxwell"
            ;;
        # Kepler (GTX 6xx-7xx): 0fc0-11ff
        0f[c-f]?|1[01]??)
            echo "kepler"
            ;;
        # Fermi (GTX 4xx-5xx): 0dc0-0fbf
        0d[c-f]?|0e??|0f[0-9ab]?)
            echo "fermi"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# nvidia_companion_for_gen GEN
#
# Maps an NVIDIA generation token to its companion package family. Callers
# pair this with `linux-cachyos-bore-<companion>` to pick the correct kernel
# module variant.
#
# Output:
#   blackwell|ada|ampere|turing -> nvidia-open
#   pascal|volta|maxwell        -> 580xx
#   kepler                      -> 470xx
#   fermi                       -> nouveau
#   anything else (incl. unknown) -> none
#
# A "none" result is a hard signal to abort the NVIDIA install path. Never
# silently downgrade to a different driver family.
nvidia_companion_for_gen() {
    local gen="${1:-}"
    case "$gen" in
        blackwell|ada|ampere|turing)
            echo "nvidia-open"
            ;;
        pascal|volta|maxwell)
            echo "580xx"
            ;;
        kepler)
            echo "470xx"
            ;;
        fermi)
            echo "nouveau"
            ;;
        *)
            echo "none"
            ;;
    esac
}
