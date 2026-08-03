<#
.SYNOPSIS
    Builds the XLA CPU PJRT plugin package on Windows (amd64).
#>

[CmdletBinding()]
param(
    [string]$XlaDir = $env:XLA_SRC_DIR
)

$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))

if (-not $XlaDir) {
    $XlaDir = $env:XLA_DIR
}
if (-not $XlaDir) {
    $XlaDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot "..\xla"))
} else {
    $XlaDir = [System.IO.Path]::GetFullPath($XlaDir)
}

Write-Host "==> Using XLA source directory: $XlaDir"
if (-not (Test-Path (Join-Path $XlaDir "configure.py"))) {
    Write-Error "XLA directory not found or invalid (missing configure.py): $XlaDir"
    exit 1
}

# 1. Setup MSVC & LLVM environment
Write-Host "==> Setting up Visual Studio & MSVC environment..."
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    $vswhere = "${env:ProgramFiles}\Microsoft Visual Studio\Installer\vswhere.exe"
}

if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found at $vswhere"
    exit 1
}

$vsDir = & $vswhere -products * -latest -property installationPath
if (-not $vsDir) {
    Write-Error "Visual Studio installation path could not be found."
    exit 1
}

$vcvars = Get-ChildItem -Path $vsDir -Filter "vcvars64.bat" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $vcvars) {
    Write-Error "vcvars64.bat not found in $vsDir"
    exit 1
}

Write-Host "Found vcvars64.bat at: $vcvars"
$envLines = cmd.exe /c "call `"$vcvars`" && set"
foreach ($line in $envLines) {
    if ($line -match '^([^=]+)=(.*)$') {
        $key = $matches[1]
        $val = $matches[2]
        if ($key -ieq "PATH") {
            $env:PATH = "$val;$env:PATH"
        } else {
            Set-Item -Path "env:$key" -Value $val
        }
    }
}

# Setup LLVM path
$llvmPath = "C:\Program Files\LLVM\bin"
if (Test-Path $llvmPath) {
    if ($env:PATH -notlike "*$llvmPath*") {
        $env:PATH = "$llvmPath;$env:PATH"
    }
}

# Verify clang-cl
$clangCl = Get-Command clang-cl -ErrorAction SilentlyContinue
if (-not $clangCl) {
    if (Test-Path "C:\Program Files\LLVM\bin\clang-cl.exe") {
        $clangCl = "C:\Program Files\LLVM\bin\clang-cl.exe"
    } else {
        Write-Error "clang-cl.exe not found. Please install LLVM."
        exit 1
    }
} else {
    $clangCl = $clangCl.Source
}
Write-Host "Found clang-cl at: $clangCl"

# 2. Extract version numbers
Write-Host "==> Extracting version numbers..."
$builderVersionFile = Join-Path $repoRoot "BUILDER_VERSION.txt"
$builderVersion = (Get-Content $builderVersionFile -Raw).Trim()

$headerFile = Join-Path $XlaDir "xla\pjrt\c\pjrt_c_api.h"
$headerContent = Get-Content $headerFile
$majorMatch = $headerContent | Select-String -Pattern '#define\s+PJRT_API_MAJOR\s+(\d+)'
$minorMatch = $headerContent | Select-String -Pattern '#define\s+PJRT_API_MINOR\s+(\d+)'

if (-not $majorMatch -or -not $minorMatch) {
    Write-Error "Failed to extract PJRT API version from $headerFile"
    exit 1
}

$major = $majorMatch.Matches[0].Groups[1].Value
$minor = $minorMatch.Matches[0].Groups[1].Value
$releaseVersion = "v${major}.${minor}.${builderVersion}"
Write-Host "Release version: $releaseVersion"

# 3. Configure XLA
Write-Host "==> Configuring XLA..."
Push-Location $XlaDir
try {
    $moduleBazel = "MODULE.bazel"
    if (Test-Path $moduleBazel) {
        $moduleContent = Get-Content $moduleBazel -Raw
        if ($moduleContent -notmatch 'rules_cc') {
            Add-Content -Path $moduleBazel -Value "`nbazel_dep(name = `"rules_cc`", version = `"0.0.17`")"
        }
    }

    # Setup dummy ROCm and CUDA packages
    $dummyRocm = Join-Path $repoRoot "dummy_rocm"
    $dummyCuda = Join-Path $repoRoot "dummy_cuda"

    New-Item -ItemType Directory -Force -Path "$dummyRocm\rocm", "$dummyCuda\cuda" | Out-Null
    New-Item -ItemType File -Force -Path "$dummyRocm\MODULE.bazel", "$dummyCuda\MODULE.bazel" | Out-Null

    @'
load("@rules_cc//cc:defs.bzl", "cc_library")
package(default_visibility = ["//visibility:public"])
cc_library(name = "rocm")

config_setting(
    name = "using_hipcc",
    values = {"define": "never_true_dummy=1"},
)
'@ | Set-Content -Path "$dummyRocm\BUILD"

    @'
load("@rules_cc//cc:defs.bzl", "cc_library")
package(default_visibility = ["//visibility:public"])
cc_library(name = "rocm")
cc_library(name = "hip")
cc_library(name = "rocm_headers")

config_setting(
    name = "using_hipcc",
    values = {"define": "never_true_dummy=1"},
)
'@ | Set-Content -Path "$dummyRocm\rocm\BUILD"

    @'
load("@rules_cc//cc:defs.bzl", "cc_library")

def if_rocm(x, default = []):
    return default
def if_rocm_is_configured(x, default = []):
    return default
def if_rocm_hip_khr_cooperative_groups(x, default = []):
    return default
def if_cuda_or_rocm(x, default = []):
    return default
def if_gpu_is_configured(x, default = []):
    return default
def is_rocm_configured():
    return False
def get_rbe_amdgpu_pool(*args, **kwargs):
    return ""
def rocm_default_copts(*args, **kwargs):
    return []
def rocm_library(name, **kwargs):
    cc_library(name = name, **kwargs)
'@ | Set-Content -Path "$dummyRocm\rocm\build_defs.bzl"
    Copy-Item "$dummyRocm\rocm\build_defs.bzl" "$dummyRocm\build_defs.bzl" -Force

    @'
load("@rules_cc//cc:defs.bzl", "cc_library")
package(default_visibility = ["//visibility:public"])
cc_library(name = "cuda")

config_setting(
    name = "is_cuda_enabled",
    values = {"define": "never_true_dummy=1"},
)
'@ | Set-Content -Path "$dummyCuda\BUILD"

    @'
load("@rules_cc//cc:defs.bzl", "cc_library")
package(default_visibility = ["//visibility:public"])
cc_library(name = "cuda")
cc_library(name = "cuda_headers")
cc_library(name = "cudnn")
cc_library(name = "cublas")
cc_library(name = "cufft")
cc_library(name = "curand")
cc_library(name = "cusolver")
cc_library(name = "cusparse")

config_setting(
    name = "using_nvcc",
    values = {"define": "never_true_dummy=1"},
)
config_setting(
    name = "is_cuda_enabled",
    values = {"define": "never_true_dummy=1"},
)
'@ | Set-Content -Path "$dummyCuda\cuda\BUILD"

    @'
load("@rules_cc//cc:defs.bzl", "cc_library")

def if_cuda(x, default = []):
    return default
def if_cuda_is_configured(x, default = []):
    return default
def if_cuda_or_rocm(x, default = []):
    return default
def if_gpu_is_configured(x, default = []):
    return default
def if_cuda_newer_than(version, if_true, if_false = []):
    return if_false
def is_cuda_configured():
    return False
def cuda_default_copts(*args, **kwargs):
    return []
def cuda_library(name, **kwargs):
    cc_library(name = name, **kwargs)
def cuda_header_library(name, **kwargs):
    cc_library(name = name, **kwargs)
def if_cuda_clang(x, default = []):
    return default
'@ | Set-Content -Path "$dummyCuda\cuda\build_defs.bzl"
    Copy-Item "$dummyCuda\cuda\build_defs.bzl" "$dummyCuda\build_defs.bzl" -Force

    $dummyRocmBazel = $dummyRocm -replace '\\', '/'
    $dummyCudaBazel = $dummyCuda -replace '\\', '/'

    if (Test-Path $moduleBazel) {
        $moduleContent = Get-Content $moduleBazel -Raw
        if ($moduleContent -notmatch 'local_config_rocm') {
            @"

local_repository_override(
    module_name = "local_config_rocm",
    path = "${dummyRocmBazel}",
)
local_repository_override(
    module_name = "local_config_cuda",
    path = "${dummyCudaBazel}",
)
"@ | Add-Content -Path $moduleBazel
        }
    }

    $env:CC = "C:/PROGRA~1/LLVM/bin/clang-cl.exe"
    $env:CXX = "C:/PROGRA~1/LLVM/bin/clang-cl.exe"
    $pyBin = (Get-Command python).Source -replace '\\', '/'
    $env:PYTHON_BIN_PATH = $pyBin
    $env:TF_NEED_ROCM = "0"
    $env:TF_NEED_CUDA = "0"

    # Run configure.py
    python configure.py --backend=cpu --os=windows --host_compiler=clang --clang_path="C:/PROGRA~1/LLVM/bin/clang.exe"

    # 4. Fix Windows paths and environment in xla_configure.bazelrc
    $bazelrc = "xla_configure.bazelrc"
    
    # Stub warnings.bazelrc to prevent -Werror from breaking MSVC/cl.exe
    $warningsFile = Join-Path $XlaDir "warnings.bazelrc"
    if (Test-Path $warningsFile) {
        Set-Content -Path $warningsFile -Value "build:warnings --copt=-D_CRT_SECURE_NO_WARNINGS`n"
    }

    # Remove python_path lines, USE_CLANG_CL, BAZEL_LLVM, and replace clang.exe with clang-cl.exe
    if (Test-Path $bazelrc) {
        $lines = Get-Content $bazelrc | Where-Object { 
            $_ -notmatch "python_path" -and 
            $_ -notmatch "-Wno-sign-compare" -and 
            $_ -notmatch "-Wno-error" -and 
            $_ -notmatch "-Wno-c23-extensions" -and
            $_ -notmatch "USE_CLANG_CL" -and
            $_ -notmatch "BAZEL_LLVM"
        }
        $lines = $lines -replace 'Program Files \(x86\)', 'PROGRA~2' -replace 'Program Files', 'PROGRA~1' -replace '\\', '/' -replace 'clang\.exe', 'clang-cl.exe'
        
        $fso = New-Object -ComObject Scripting.FileSystemObject
        $vcDir = Join-Path $vsDir "VC"
        if (Test-Path $vcDir) {
            $shortVc = $fso.GetFolder($vcDir).ShortPath
            $bazelVc = $shortVc -replace '\\', '/'
        } else {
            $bazelVc = "C:/PROGRA~2/MICROS~3/2022/BUILDT~1/VC"
        }

        $extraFlags = @"
build --compiler=clang-cl
build --copt=-MT
build --features=-compiler_param_file
build --features=archive_param_file
build --features=linker_param_file
build --linkopt=/FORCE:MULTIPLE
build --action_env=CC=C:/PROGRA~1/LLVM/bin/clang-cl.exe
build --action_env=CXX=C:/PROGRA~1/LLVM/bin/clang-cl.exe
build --repo_env=CC=C:/PROGRA~1/LLVM/bin/clang-cl.exe
build --repo_env=CXX=C:/PROGRA~1/LLVM/bin/clang-cl.exe
build --repo_env=USE_CLANG_CL=1
build --repo_env=BAZEL_LLVM=C:/PROGRA~1/LLVM
build --repo_env=BAZEL_LLVM_RESPECT_CLANG_ONLY=1
build --action_env=BAZEL_COMPILER=clang-cl
build --repo_env=BAZEL_COMPILER=clang-cl
build --action_env=BAZEL_SH=C:/PROGRA~1/Git/bin/bash.exe
build --repo_env=BAZEL_SH=C:/PROGRA~1/Git/bin/bash.exe
"@
        $cleanContent = ($lines -join "`n") + "`n" + $extraFlags
        Set-Content -Path $bazelrc -Value $cleanContent
    }

    # Patch rules_cc in user output root if present
    Get-ChildItem -Path "C:\b" -Filter "windows_cc_configure.bzl" -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        (Get-Content $_.FullName) -replace 'build_tools\["DUMPBIN"\]', 'build_tools.get("DUMPBIN", "dumpbin.exe")' | Set-Content $_.FullName
    }

    # Apply patch
    $patchFile = Join-Path $repoRoot "internal\patches\windows\export.patch"
    if (Test-Path $patchFile) {
        Write-Host "Applying dllexport patch..."
        Set-Location $XlaDir
        git apply --ignore-whitespace --3way $patchFile
        Set-Location $repoRoot
    }

    # Patch filewrapper.cc in XLA source tree if needed
    $fwFile = Join-Path $XlaDir "xla/tsl/util/filewrapper.cc"
    if (Test-Path $fwFile) {
        $fwContent = Get-Content $fwFile -Raw
        if ($fwContent -match "#if defined\(COMPILER_MSVC\)\\n") {
            $fwContent = $fwContent -replace '#if defined\(COMPILER_MSVC\)\\n', "#if defined(COMPILER_MSVC) || defined(_MSC_VER) || defined(__clang__)\n"
            Set-Content $fwFile -Value $fwContent
        }
    }

    # Patch snappy BUILD.bazel if present in cache to replace broken sed genrule (exclude install directory)
    Get-ChildItem -Path "C:\b_root" -Filter "BUILD.bazel" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "install" -and $_.FullName -match "snappy" } | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        if ($content -match "snappy_stubs_public_h" -and $content -match "sed") {
            $pyGen = @'
cmd = "python -c \"import sys; text = open(sys.argv[1]).read().replace('\\$${HAVE_SYS_UIO_H_01}', '0').replace('\\$${PROJECT_VERSION_MAJOR}', '1').replace('\\$${PROJECT_VERSION_MINOR}', '2').replace('\\$${PROJECT_VERSION_PATCH}', '2'); open(sys.argv[2], 'w').write(text)\" $< $@"
'@
            $content -replace '(?s)cmd = \("""sed.*?\%\s*SNAPPY_VERSION\)', $pyGen | Set-Content $_.FullName
        }
    }

    # 5. Execute Build
    Write-Host "==> Running Bazel build..."
    Set-Location $XlaDir

    $env:BAZEL_SH = "C:/Program Files/Git/bin/bash.exe"
    $env:PATH = "C:\Program Files\Git\bin;$env:PATH"
    if (Test-Path "C:\Program Files\LLVM\lib\clang\22\include") {
        $env:INCLUDE = "C:\Program Files\LLVM\lib\clang\22\include;$env:INCLUDE"
    }
    $env:CC = "C:/PROGRA~1/LLVM/bin/clang-cl.exe"
    $env:CXX = "C:/PROGRA~1/LLVM/bin/clang-cl.exe"
    $env:USE_CLANG_CL = "1"
    $env:BAZEL_LLVM = "C:/PROGRA~1/LLVM"
    $env:BAZEL_LLVM_RESPECT_CLANG_ONLY = "1"
    $env:BAZEL_COMPILER = "clang-cl"

    # Patch net_zstd BUILD.bazel if present in external/ cache to remove .S files on Windows
    Get-ChildItem -Path "C:\b_root" -Filter "BUILD.bazel" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "external" -and $_.FullName -notmatch "install" -and $_.FullName -match "net_zstd" } | ForEach-Object {
        (Get-Content $_.FullName -Raw) -replace 'glob\(\["decompress/\*_amd64\.S"\]\)', '[]' | Set-Content $_.FullName
    }

    # Patch external rules_cc if present in external/ cache (never touch install/)
    Get-ChildItem -Path "C:\b_root" -Filter "windows_cc_configure.bzl" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "external" -and $_.FullName -notmatch "install" } | ForEach-Object {
        $content = Get-Content $_.FullName -Raw
        $content = $content -replace 'build_tools\["DUMPBIN"\]', 'build_tools.get("DUMPBIN", "dumpbin.exe")'
        $content = $content -replace 'return first_line\.split\(" "\)\[-1\]', 'return first_line.split("clang version ")[1].split(" ")[0]'
        Set-Content $_.FullName -Value $content
    }

    $buildArgs = @(
        "build",
        "--override_repository=local_config_rocm=${dummyRocmBazel}",
        "--override_repository=local_config_cuda=${dummyCudaBazel}",
        "--override_repository=local_config_rocm_ext=${dummyRocmBazel}",
        "--incompatible_enable_cc_toolchain_resolution=false",
        "--check_direct_dependencies=off",
        "--config=clang_local",
        "--linkopt=--ld-path=C:/PROGRA~1/LLVM/bin/ld.lld.exe",
        "--repo_env=CC=C:/PROGRA~1/LLVM/bin/clang-cl.exe",
        "--repo_env=CXX=C:/PROGRA~1/LLVM/bin/clang-cl.exe",
        "--repo_env=USE_CLANG_CL=1",
        "--repo_env=BAZEL_LLVM=C:/PROGRA~1/LLVM",
        "--repo_env=BAZEL_LLVM_RESPECT_CLANG_ONLY=1",
        "--repo_env=BAZEL_COMPILER=clang-cl",
        "--repo_env=TF_NEED_ROCM=0",
        "--repo_env=TF_NEED_CUDA=0",
        "--copt=-march=native",
        "--copt=-mavx2",
        "--copt=-mfma",
        "--copt=-mf16c",
        "--copt=-mbmi",
        "--copt=-mbmi2",
        "--copt=-mlzcnt",
        "--copt=-MT",
        "--copt=-D_CRT_SECURE_NO_WARNINGS",
        "--copt=-DZSTD_DISABLE_ASM=1",
        "--host_copt=-DZSTD_DISABLE_ASM=1",
        "--copt=-mamx-tile",
        "--copt=-mamx-fp16",
        "--copt=-mamx-bf16",
        "--copt=-mamx-int8",
        "//xla/pjrt/c:pjrt_c_api_cpu_plugin.so"
    )

    & bazel --output_user_root="C:/b_root" @buildArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Initial build invocation completed. Patching external rules_cc and retrying..."
        Get-ChildItem -Path "C:\b_root" -Filter "windows_cc_configure.bzl" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match "external" -and $_.FullName -notmatch "install" } | ForEach-Object {
            $content = Get-Content $_.FullName -Raw
            $content = $content -replace 'build_tools\["DUMPBIN"\]', 'build_tools.get("DUMPBIN", "dumpbin.exe")'
            $content = $content -replace 'return first_line\.split\(" "\)\[-1\]', 'return first_line.split("clang version ")[1].split(" ")[0]'
            Set-Content $_.FullName -Value $content
        }
        & bazel --output_user_root="C:/b_root" @buildArgs
    }

    # 6. Package the binary
    Write-Host "==> Packaging binary..."
    $zipName = "pjrt_cpu_windows_amd64.zip"
    $binDir = Join-Path $XlaDir "bazel-bin\xla\pjrt\c"
    $binFile = Join-Path $binDir "pjrt_c_api_cpu_plugin.so"
    if (-not (Test-Path $binFile)) {
        $binFile = Join-Path $binDir "pjrt_c_api_cpu_plugin.dll"
    }

    $targetName = "pjrt_c_api_cpu_${releaseVersion}_plugin.dll"
    $outZipPath = Join-Path $repoRoot $zipName
    $targetFilePath = Join-Path $repoRoot $targetName

    Copy-Item $binFile $targetFilePath -Force
    Compress-Archive -Path $targetFilePath -DestinationPath $outZipPath -Force
    Write-Host "Successfully packaged binary to $outZipPath"
}
finally {
    Pop-Location
}
