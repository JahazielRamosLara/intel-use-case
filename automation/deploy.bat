@echo off
setlocal EnableDelayedExpansion

rem ==============================================================
rem  Intel DevOps Assessment - Script de Automatizacion (Windows)
rem  Online Boutique Deployment + Monitoring (Prometheus & Grafana)
rem ==============================================================
rem  Uso: Abrir cmd como administrador y ejecutar: deploy.bat
rem  Descripcion: Automatiza el despliegue completo de la Online Boutique
rem               en GKE junto con el stack de monitoreo. Instala automaticamente
rem               las dependencias si no estan presentes.
rem ==============================================================

color 0F

:: Variables de configuracion
set "PROJECT_ID=intel-boutique-demo"
set "ZONE=us-east1-b"
set "CLUSTER_NAME=boutique-cluster"
set "NUM_NODES=3"
set "DISK_SIZE=80"
set "MACHINE_TYPE=e2-medium"
set "MONITORING_NAMESPACE=monitoring"
set "REPO_URL=https://github.com/GoogleCloudPlatform/microservices-demo.git"
set "REPO_DIR=microservices-demo"
set "SCRIPT_DIR=%~dp0"

:: ==============================================================
:: PASO 0: Verificar e instalar dependencias
:: ==============================================================
echo ============================================================
echo  Intel DevOps Assessment - Automatizacion de Despliegue
echo ============================================================
echo.
echo [INFO] === PASO 0: Verificando e instalando dependencias ===

:: Verificar gcloud
where gcloud >nul 2>&1
if !errorlevel! neq 0 (
    echo [WARN] gcloud no encontrado. Instalando...
    echo [INFO] Descargando Google Cloud SDK...
    powershell -Command "Invoke-WebRequest -Uri 'https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe' -OutFile '%TEMP%\GoogleCloudSDKInstaller.exe'"
    echo [INFO] Ejecutando instalador de Google Cloud SDK...
    echo [INFO] Por favor, sigue las instrucciones del instalador.
    start /wait "%TEMP%\GoogleCloudSDKInstaller.exe"
    del "%TEMP%\GoogleCloudSDKInstaller.exe"
    echo [INFO] Por favor, cierra y reabre cmd, luego ejecuta deploy.bat de nuevo.
    pause
    exit /b 0
) else (
    echo [OK] gcloud encontrado
)

:: Verificar kubectl
where kubectl >nul 2>&1
if !errorlevel! neq 0 (
    echo [WARN] kubectl no encontrado. Instalando...
    echo [INFO] gcloud puede instalar kubectl automaticamente.
    cmd /c gcloud components install kubectl
    if !errorlevel! neq 0 (
        echo [ERROR] Fallo la instalacion de kubectl.
        echo [INFO] Instalalo manualmente: https://kubernetes.io/docs/tasks/tools/
        pause
        exit /b 1
    )
    echo [OK] kubectl instalado
) else (
    echo [OK] kubectl encontrado
)

:: Verificar helm
where helm >nul 2>&1
if !errorlevel! neq 0 (
    echo [WARN] helm no encontrado. Instalando...
    echo [INFO] Descargando Helm...
    powershell -Command "Invoke-WebRequest -Uri 'https://get.helm.sh/helm-v3.13.0-windows-amd64.zip' -OutFile '%TEMP%\helm.zip'"
    echo [INFO] Extrayendo Helm...
    powershell -Command "Expand-Archive -Path '%TEMP%\helm.zip' -DestinationPath '%TEMP%\helm' -Force"
    echo [INFO] Instalando Helm...
    if not exist "C:\Program Files\helm" mkdir "C:\Program Files\helm"
    move /Y "%TEMP%\helm\windows-amd64\helm.exe" "C:\Program Files\helm\helm.exe" >nul 2>&1
    del "%TEMP%\helm.zip"
    rd /s /q "%TEMP%\helm"
    echo [OK] helm instalado
) else (
    echo [OK] helm encontrado
)

:: Verificar git
where git >nul 2>&1
if !errorlevel! neq 0 (
    echo [WARN] git no encontrado. Instalando...
    echo [INFO] Descargando Git...
    powershell -Command "Invoke-WebRequest -Uri 'https://github.com/git-for-windows/git/releases/download/v2.43.0.windows.1/Git-2.43.0-64-bit.exe' -OutFile '%TEMP%\GitInstaller.exe'"
    echo [INFO] Ejecutando instalador de Git...
    echo [INFO] Por favor, sigue las instrucciones del instalador con las opciones por defecto.
    start /wait "%TEMP%\GitInstaller.exe"
    del "%TEMP%\GitInstaller.exe"
    echo [INFO] Por favor, cierra y reabre cmd para que Git este en el PATH, luego ejecuta deploy.bat de nuevo.
    pause
    exit /b 0
) else (
    echo [OK] git encontrado
)

echo.

:: ==============================================================
:: PASO 1: Verificar proyecto GCP
:: ==============================================================
echo [INFO] === PASO 1: Verificando proyecto GCP ===

cmd /c gcloud projects describe "%PROJECT_ID%" >nul 2>&1
set PROJECT_CHECK=!errorlevel!
if !PROJECT_CHECK! neq 0 (
    echo [ERROR] El proyecto '%PROJECT_ID%' no existe en GCP.
    echo [INFO] Crealo en: https://console.cloud.google.com
    pause
    exit /b 1
)
echo [OK] Proyecto GCP '%PROJECT_ID%' verificado

cmd /c gcloud config set project "%PROJECT_ID%" >nul 2>&1
echo [OK] Proyecto activo configurado
echo.

:: ==============================================================
:: PASO 2: Crear el cluster de GKE
:: ==============================================================
echo [INFO] === PASO 2: Creando cluster de GKE ===

cmd /c gcloud container clusters describe "%CLUSTER_NAME%" --zone="%ZONE%" >nul 2>&1
set CLUSTER_CHECK=!errorlevel!
if !CLUSTER_CHECK! equ 0 (
    echo [WARN] El cluster '%CLUSTER_NAME%' ya existe. Se salta la creacion.
) else (
    echo [INFO] Habilitando el servicio de GKE...
    cmd /c gcloud services enable container.googleapis.com
    echo [INFO] Creando cluster '%CLUSTER_NAME%' en zona %ZONE% con %NUM_NODES% nodos...
    cmd /c gcloud container clusters create "%CLUSTER_NAME%" --zone="%ZONE%" --num-nodes=%NUM_NODES% --machine-type="%MACHINE_TYPE%" --disk-size=%DISK_SIZE% --project="%PROJECT_ID%"
    if !errorlevel! neq 0 (
        echo [ERROR] Fallo la creacion del cluster.
        pause
        exit /b 1
    )
    echo [OK] Cluster creado exitosamente
)

echo [INFO] Conectando kubectl al cluster...
cmd /c gcloud container clusters get-credentials "%CLUSTER_NAME%" --zone="%ZONE%" --project="%PROJECT_ID%"
echo [OK] kubectl conectado al cluster
echo.

:: ==============================================================
:: PASO 3: Desplegar la Online Boutique
:: ==============================================================
echo [INFO] === PASO 3: Desplegando Online Boutique ===

if not exist "%REPO_DIR%" (
    echo [INFO] Clonando repositorio...
    git clone "%REPO_URL%"
    echo [OK] Repositorio clonado
) else (
    echo [WARN] El directorio '%REPO_DIR%' ya existe. Se salta el clon.
)

cd "%REPO_DIR%"

echo [INFO] Ajustando recursos del loadgenerator...
powershell -Command "(Get-Content kustomize\base\loadgenerator.yaml) -replace 'cpu: 300m','cpu: 50m' -replace 'memory: 256Mi','memory: 64Mi' -replace 'cpu: 500m','cpu: 100m' -replace 'memory: 512Mi','memory: 128Mi' | Set-Content kustomize\base\loadgenerator.yaml"

echo [INFO] Ajustando recursos de los servicios...
powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%adjust-resources.ps1"

echo [INFO] Desplegando Online Boutique...
kubectl apply -k ./kustomize/
if !errorlevel! neq 0 (
    echo [ERROR] Fallo el despliegue de la Online Boutique.
    pause
    exit /b 1
)

echo [INFO] Esperando a que los pods esten listos (puede tardar 1-2 minutos)...
timeout /t 60 /nobreak >nul
kubectl get pods
echo.
cd ..

:: ==============================================================
:: PASO 4: Instalar Prometheus + Grafana
:: ==============================================================
echo [INFO] === PASO 4: Instalando stack de monitoreo ===

kubectl create namespace "%MONITORING_NAMESPACE%" --dry-run=client -o yaml | kubectl apply -f -

echo [INFO] Agregando repositorio de Helm...
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm list -n "%MONITORING_NAMESPACE%" | findstr "prometheus" >nul 2>&1
set HELM_CHECK=!errorlevel!
if !HELM_CHECK! equ 0 (
    echo [WARN] Prometheus ya esta instalado. Se salta la instalacion.
) else (
    echo [INFO] Instalando kube-prometheus-stack...
    helm install prometheus prometheus-community/kube-prometheus-stack --namespace "%MONITORING_NAMESPACE%"
    if !errorlevel! neq 0 (
        echo [ERROR] Fallo la instalacion de Prometheus.
        pause
        exit /b 1
    )
    echo [OK] kube-prometheus-stack instalado
)

echo [INFO] Exponiendo Grafana con IP publica...
echo {"spec":{"type":"LoadBalancer"}} >temp_patch.json
kubectl patch service prometheus-grafana --namespace monitoring -p @temp_patch.json
del temp_patch.json

echo [INFO] Esperando IP externa de Grafana...
timeout /t 30 /nobreak >nul
echo.

:: ==============================================================
:: PASO 5: Informacion de acceso
:: ==============================================================
echo [INFO] === PASO 5: Informacion de acceso ===
echo.

kubectl get service frontend-external -o jsonpath={.status.loadBalancer.ingress[0].ip} >temp_ip.txt 2>&1
set /p FRONTEND_IP=<temp_ip.txt
kubectl get service prometheus-grafana --namespace monitoring -o jsonpath={.status.loadBalancer.ingress[0].ip} >temp_ip.txt 2>&1
set /p GRAFANA_IP=<temp_ip.txt
kubectl get secret prometheus-grafana --namespace monitoring -o jsonpath={.data.admin-password} >temp_ip.txt 2>&1
set /p GRAFANA_PASS_B64=<temp_ip.txt
del temp_ip.txt

echo ============================================================
echo  DESPLIEGUE COMPLETADO EXITOSAMENTE
echo ============================================================
echo.
echo  Online Boutique:
echo    URL: http://!FRONTEND_IP!
echo.
echo  Grafana (Dashboard de metricas):
echo    URL: http://!GRAFANA_IP!
echo    Usuario: admin
echo    Contrasena (base64): !GRAFANA_PASS_B64!
echo    (Decodifica la contrasena manualmente con base64)
echo.
echo  Queries recomendadas en Grafana:
echo    CPU por pod:
echo      sum(rate(container_cpu_usage_seconds_total{namespace="default"}[5m])) by (pod)
echo    Memoria por pod:
echo      sum(container_memory_working_set_bytes{namespace="default"}) by (pod)
echo.
echo ============================================================

endlocal
