@echo off
  setlocal enabledelayedexpansion

  set "PATH=C:\Program Files\7-Zip;%PATH%"

  where /q git.exe || (
    echo ERROR: git.exe not found
    exit /b 1
  )

  if exist "%ProgramFiles%\7-Zip\7z.exe" (
    set "SZIP=%ProgramFiles%\7-Zip\7z.exe"
  ) else (
    where /q 7za.exe || (
      echo ERROR: 7-Zip installation or 7za.exe not found
      exit /b 1
    )
    set "SZIP=7za.exe"
  )

  rem *** Validate user-provided Aseprite version before using it in commands.

  if not "%ASEPRITE_VERSION%" equ "" (
    echo %ASEPRITE_VERSION%| findstr /R "^v[0-9][0-9]*\.[0-9][0-9]*" >nul || (
      echo ERROR: invalid ASEPRITE_VERSION: %ASEPRITE_VERSION%
      exit /b 1
    )
  )


  rem *** Visual Studio environment ***

  where /Q cl.exe || (
    set "__VSCMD_ARG_NO_LOGO=1"
    for /f "tokens=*" %%i in ('"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -requires
    Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath') do set "VS=%%i"
    if "!VS!" equ "" (
      echo ERROR: Visual Studio installation not found
      exit /b 1
    )
    call "!VS!\VC\Auxiliary\Build\vcvarsall.bat" amd64 || (
      echo ERROR: failed to initialize Visual Studio environment
      exit /b 1
    )
  )


  rem *** ninja

  where /q ninja.exe || (
    curl -LOsf https://github.com/ninja-build/ninja/releases/download/v1.13.1/ninja-win.zip || (
      echo ERROR: failed to download ninja
      exit /b 1
    )

    certutil -hashfile ninja-win.zip SHA256 | findstr /I "26A40FA8595694DEC2FAD4911E62D29E10525D2133C9A4230B66397774AE25BF" >nul || (
      echo ERROR: ninja-win.zip checksum mismatch
      exit /b 1
    )

    "%SZIP%" x -bb0 -y ninja-win.zip 1>nul 2>nul || (
      echo ERROR: failed to extract ninja
      exit /b 1
    )

    del ninja-win.zip 1>nul 2>nul
  )


  rem *** clone aseprite repo

  if not exist aseprite (
    call git clone --recursive --tags https://github.com/aseprite/aseprite.git aseprite || (
      echo ERROR: failed to clone aseprite repo
      exit /b 1
    )
  ) else (
    call git -C aseprite fetch --tags || (
      echo ERROR: failed to fetch aseprite repo
      exit /b 1
    )
  )


  rem *** get name of newest tag

  if "%ASEPRITE_VERSION%" equ "" (
    for /F "delims=" %%v in ('"git -C aseprite tag --sort=creatordate"') do (
      set "ASEPRITE_VERSION=%%v"
    )
  )

  if "%ASEPRITE_VERSION%" equ "" (
    echo ERROR: failed to resolve ASEPRITE_VERSION
    exit /b 1
  )

  echo %ASEPRITE_VERSION%| findstr /R "^v[0-9][0-9]*\.[0-9][0-9]*" >nul || (
    echo ERROR: invalid resolved ASEPRITE_VERSION: %ASEPRITE_VERSION%
    exit /b 1
  )

  echo building %ASEPRITE_VERSION%


  rem **** update local aseprite repo to selected tag

  call git -C aseprite clean --quiet -fdx || (
    echo ERROR: failed to clean aseprite repo
    exit /b 1
  )

  call git -C aseprite submodule foreach --recursive git clean -xfd || (
    echo ERROR: failed to clean aseprite submodules
    exit /b 1
  )

  call git -C aseprite fetch --quiet --depth=1 origin tag %ASEPRITE_VERSION% || (
    echo ERROR: failed to fetch aseprite tag %ASEPRITE_VERSION%
    exit /b 1
  )

  call git -C aseprite reset --quiet --hard %ASEPRITE_VERSION% || (
    echo ERROR: failed to reset aseprite repo to %ASEPRITE_VERSION%
    exit /b 1
  )

  call git -C aseprite submodule update --init --recursive || (
    echo ERROR: failed to update aseprite submodules
    exit /b 1
  )

  python -c "v = open('aseprite/src/ver/CMakeLists.txt').read(); open('aseprite/src/ver/CMakeLists.txt', 'w').write(v.replace('1.x-dev',
  '%ASEPRITE_VERSION%'[1:]))" || (
    echo ERROR: failed to patch aseprite version file
    exit /b 1
  )


  rem *** download skia

  if exist aseprite\laf\misc\skia-tag.txt (
    set /p SKIA_VERSION=<aseprite\laf\misc\skia-tag.txt
  ) else (
    if "%ASEPRITE_VERSION:beta=%" neq "%ASEPRITE_VERSION%" (
      set "SKIA_VERSION=m124-08a5439a6b"
    ) else (
      set "SKIA_VERSION=m102-861e4743af"
    )
  )

  echo %SKIA_VERSION%| findstr /R "^m[0-9][0-9]*-[0-9a-fA-F][0-9a-fA-F]*$" >nul || (
    echo ERROR: invalid SKIA_VERSION: %SKIA_VERSION%
    exit /b 1
  )

  if not exist skia-%SKIA_VERSION% (
    mkdir skia-%SKIA_VERSION% || (
      echo ERROR: failed to create skia directory
      exit /b 1
    )

    pushd skia-%SKIA_VERSION% || (
      echo ERROR: failed to enter skia directory
      exit /b 1
    )

    curl -sfLO https://github.com/aseprite/skia/releases/download/%SKIA_VERSION%/Skia-Windows-Release-x64.zip || (
      echo ERROR: failed to download skia
      exit /b 1
    )

    "%SZIP%" x -y Skia-Windows-Release-x64.zip || (
      echo ERROR: failed to extract skia
      exit /b 1
    )

    popd
  )


  rem *** build aseprite

  if exist build rd /s /q build

  set "LINK=opengl32.lib"

  cmake.exe                                                     ^
    -G Ninja                                                    ^
    -S aseprite                                                 ^
    -B build                                                    ^
    -DCMAKE_BUILD_TYPE=Release                                  ^
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5                          ^
    -DCMAKE_POLICY_DEFAULT_CMP0074=NEW                          ^
    -DCMAKE_POLICY_DEFAULT_CMP0091=NEW                          ^
    -DCMAKE_POLICY_DEFAULT_CMP0092=NEW                          ^
    -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded                  ^
    -DENABLE_CCACHE=OFF                                         ^
    -DOPENSSL_USE_STATIC_LIBS=TRUE                              ^
    -DLAF_BACKEND=skia                                          ^
    "-DSKIA_DIR=%CD%\skia-%SKIA_VERSION%"                       ^
    "-DSKIA_LIBRARY_DIR=%CD%\skia-%SKIA_VERSION%\out\Release-x64" ^
    -DSKIA_OPENGL_LIBRARY=                                      || (
      echo ERROR: failed to configure build
      exit /b 1
    )

  ninja.exe -C build || (
    echo ERROR: build failed
    exit /b 1
  )


  rem *** create output folder

  mkdir aseprite-%ASEPRITE_VERSION% || (
    echo ERROR: failed to create output folder
    exit /b 1
  )

  echo # This file is here so Aseprite behaves as a portable program >aseprite-%ASEPRITE_VERSION%\aseprite.ini

  xcopy /E /Q /Y aseprite\docs aseprite-%ASEPRITE_VERSION%\docs\ || (
    echo ERROR: failed to copy docs
    exit /b 1
  )

  xcopy /E /Q /Y build\bin\aseprite.exe aseprite-%ASEPRITE_VERSION%\ || (
    echo ERROR: failed to copy aseprite.exe
    exit /b 1
  )

  xcopy /E /Q /Y build\bin\data aseprite-%ASEPRITE_VERSION%\data\ || (
    echo ERROR: failed to copy data
    exit /b 1
  )

  if "%GITHUB_WORKFLOW%" neq "" (
    mkdir github || (
      echo ERROR: failed to create github artifact folder
      exit /b 1
    )

    move aseprite-%ASEPRITE_VERSION% github\ || (
      echo ERROR: failed to move artifact folder
      exit /b 1
    )

    >>"%GITHUB_OUTPUT%" echo ASEPRITE_VERSION=%ASEPRITE_VERSION%
  )
