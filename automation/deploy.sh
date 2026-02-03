#!/bin/bash
#==============================================================================
# Intel DevOps Assessment - Script de Automatización
# Online Boutique Deployment + Monitoring (Prometheus & Grafana)
#==============================================================================
# Uso: bash deploy.sh
# Descripción: Automatiza el despliegue completo de la Online Boutique
#              en GKE junto con el stack de monitoreo. Instala automáticamente
#              las dependencias si no están presentes.
#==============================================================================

set -e  # El script se detiene si algún comando falla

#------------------------------------------------------------------------------
# VARIABLES DE CONFIGURACIÓN
# Modifica estas variables según tu entorno
#------------------------------------------------------------------------------
PROJECT_ID="intel-boutique-demo"
ZONE="us-east1-b"
CLUSTER_NAME="boutique-cluster"
NUM_NODES=3
DISK_SIZE=80                          # GB por nodo
MACHINE_TYPE="e2-medium"
MONITORING_NAMESPACE="monitoring"
REPO_URL="https://github.com/GoogleCloudPlatform/microservices-demo.git"
REPO_DIR="microservices-demo"

#------------------------------------------------------------------------------
# COLORES para mensajes en la terminal
#------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color (resetea el color)

#------------------------------------------------------------------------------
# FUNCIONES auxiliares
#------------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

wait_for_pods() {
    # Espera a que todos los pods estén en Running
    # Argumento 1: namespace
    # Argumento 2: cantidad esperada de pods
    local namespace=$1
    local expected=$2
    local timeout=300  # 5 minutos máximo
    local elapsed=0

    log_info "Esperando a que los pods estén listos..."
    while [ $elapsed -lt $timeout ]; do
        local ready=$(kubectl get pods --namespace "$namespace" | grep -c "Running" || true)
        local total=$(kubectl get pods --namespace "$namespace" | grep -c -E "Running|Pending|ContainerCreating|Init:" || true)
        echo "  Pods Running: $ready / $expected"

        if [ "$ready" -eq "$expected" ]; then
            log_success "Todos los pods están en Running"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    log_warn "Timeout esperando pods. Algunos podrían no estar listos."
    return 1
}

install_gcloud() {
    log_info "Instalando Google Cloud SDK..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install --cask google-cloud-sdk
        else
            log_error "Homebrew no está instalado. Instala Homebrew primero: https://brew.sh"
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        curl https://sdk.cloud.google.com | bash
        exec -l $SHELL
    else
        log_error "Sistema operativo no soportado para instalación automática. Instala gcloud manualmente: https://cloud.google.com/sdk/docs/install"
    fi
    log_success "gcloud instalado"
}

install_kubectl() {
    log_info "Instalando kubectl..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install kubectl
        else
            curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/darwin/amd64/kubectl"
            chmod +x kubectl
            sudo mv kubectl /usr/local/bin/
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        chmod +x kubectl
        sudo mv kubectl /usr/local/bin/
    fi
    log_success "kubectl instalado"
}

install_helm() {
    log_info "Instalando Helm..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install helm
        else
            curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    log_success "Helm instalado"
}

install_git() {
    log_info "Instalando Git..."
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        if command -v brew &> /dev/null; then
            brew install git
        else
            log_error "Homebrew no está instalado. Instala Homebrew primero: https://brew.sh"
        fi
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            sudo apt-get update && sudo apt-get install -y git
        elif command -v yum &> /dev/null; then
            sudo yum install -y git
        else
            log_error "No se pudo detectar el gestor de paquetes. Instala git manualmente."
        fi
    fi
    log_success "Git instalado"
}

#------------------------------------------------------------------------------
# PASO 0: Instalar dependencias si no están presentes
#------------------------------------------------------------------------------
install_dependencies() {
    log_info "=== PASO 0: Verificando e instalando dependencias ==="
    
    # Verificar gcloud
    if ! command -v gcloud &> /dev/null; then
        log_warn "gcloud no encontrado. Instalando..."
        install_gcloud
    else
        log_success "gcloud encontrado"
    fi

    # Verificar kubectl
    if ! command -v kubectl &> /dev/null; then
        log_warn "kubectl no encontrado. Instalando..."
        install_kubectl
    else
        log_success "kubectl encontrado"
    fi

    # Verificar helm
    if ! command -v helm &> /dev/null; then
        log_warn "helm no encontrado. Instalando..."
        install_helm
    else
        log_success "helm encontrado"
    fi

    # Verificar git
    if ! command -v git &> /dev/null; then
        log_warn "git no encontrado. Instalando..."
        install_git
    else
        log_success "git encontrado"
    fi

    echo ""
}

#------------------------------------------------------------------------------
# PASO 1: Verificar prerrequisitos
#------------------------------------------------------------------------------
check_prerequisites() {
    log_info "=== PASO 1: Verificando proyecto GCP ==="

    # Verificar que el proyecto GCP existe
    if ! gcloud projects describe "$PROJECT_ID" &> /dev/null; then
        log_error "El proyecto '$PROJECT_ID' no existe en GCP. Créalo en la consola."
    fi
    log_success "Proyecto GCP '$PROJECT_ID' verificado"

    # Configurar el proyecto activo
    gcloud config set project "$PROJECT_ID"
    log_success "Proyecto activo configurado"
    echo ""
}

#------------------------------------------------------------------------------
# PASO 2: Crear el clúster de GKE
#------------------------------------------------------------------------------
create_cluster() {
    log_info "=== PASO 2: Creando clúster de GKE ==="

    # Verificar si el clúster ya existe
    if gcloud container clusters describe "$CLUSTER_NAME" --zone="$ZONE" &> /dev/null; then
        log_warn "El clúster '$CLUSTER_NAME' ya existe. Se salta la creación."
    else
        log_info "Habilitando el servicio de GKE..."
        gcloud services enable container.googleapis.com

        log_info "Creando clúster '$CLUSTER_NAME' en zona $ZONE con $NUM_NODES nodos..."
        gcloud container clusters create "$CLUSTER_NAME" \
            --zone="$ZONE" \
            --num-nodes="$NUM_NODES" \
            --machine-type="$MACHINE_TYPE" \
            --disk-size="$DISK_SIZE" \
            --project="$PROJECT_ID" || log_error "Falló la creación del clúster. Revisa la cuota de tu proyecto."

        log_success "Clúster creado exitosamente"
    fi

    # Conectar kubectl al clúster
    log_info "Conectando kubectl al clúster..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" --zone="$ZONE" --project="$PROJECT_ID"
    log_success "kubectl conectado al clúster"
    echo ""
}

#------------------------------------------------------------------------------
# PASO 3: Desplegar la Online Boutique
#------------------------------------------------------------------------------
deploy_boutique() {
    log_info "=== PASO 3: Desplegando Online Boutique ==="

    # Clonar el repositorio si no existe
    if [ ! -d "$REPO_DIR" ]; then
        log_info "Clonando repositorio..."
        git clone "$REPO_URL"
        log_success "Repositorio clonado"
    else
        log_warn "El directorio '$REPO_DIR' ya existe. Se salta el clon."
    fi

    cd "$REPO_DIR"

    # Ajustar recursos del loadgenerator
    log_info "Ajustando recursos del loadgenerator..."
    sed -i.bak 's/cpu: 300m/cpu: 50m/g; s/memory: 256Mi/memory: 64Mi/g; s/cpu: 500m/cpu: 100m/g; s/memory: 512Mi/memory: 128Mi/g' \
        kustomize/base/loadgenerator.yaml

    # Ajustar recursos de los demás servicios
    log_info "Ajustando recursos de los servicios..."
    for file in kustomize/base/*.yaml; do
        # Cambiar los CPU requests a 50m y limits a 100m
        sed -i.bak '/requests:/,/cpu:/ s/cpu: [0-9]*m/cpu: 50m/; /limits:/,/cpu:/ s/cpu: [0-9]*m/cpu: 100m/' "$file"
    done

    # Desplegar
    log_info "Desplegando Online Boutique..."
    kubectl apply -k ./kustomize/ || log_error "Falló el despliegue de la Online Boutique"

    wait_for_pods "default" 12
    echo ""
    cd ..
}

#------------------------------------------------------------------------------
# PASO 4: Instalar Prometheus + Grafana
#------------------------------------------------------------------------------
install_monitoring() {
    log_info "=== PASO 4: Instalando stack de monitoreo ==="

    # Crear namespace de monitoreo si no existe
    kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Agregar repositorio de Helm
    log_info "Agregando repositorio de Helm..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    helm repo update

    # Instalar kube-prometheus-stack si no está instalado
    if helm list -n "$MONITORING_NAMESPACE" | grep -q "prometheus"; then
        log_warn "Prometheus ya está instalado. Se salta la instalación."
    else
        log_info "Instalando kube-prometheus-stack..."
        helm install prometheus prometheus-community/kube-prometheus-stack \
            --namespace "$MONITORING_NAMESPACE" || log_error "Falló la instalación de Prometheus"
        log_success "kube-prometheus-stack instalado"
    fi

    # Exponer Grafana con IP pública
    log_info "Exponiendo Grafana con IP pública..."
    kubectl patch service prometheus-grafana \
        --namespace "$MONITORING_NAMESPACE" \
        -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null || log_warn "Grafana ya está expuesto"

    log_info "Esperando IP externa de Grafana..."
    sleep 30
    echo ""
}

#------------------------------------------------------------------------------
# PASO 5: Mostrar información de acceso
#------------------------------------------------------------------------------
show_access_info() {
    log_info "=== PASO 5: Información de acceso ==="
    echo ""

    # Obtener IP del frontend
    FRONTEND_IP=$(kubectl get service frontend-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "Pendiente")

    # Obtener IP de Grafana
    GRAFANA_IP=$(kubectl get service prometheus-grafana --namespace "$MONITORING_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "Pendiente")

    # Obtener contraseña de Grafana (en base64)
    GRAFANA_PASS=$(kubectl get secret prometheus-grafana --namespace "$MONITORING_NAMESPACE" -o jsonpath='{.data.admin-password}' 2>/dev/null || echo "")

    # Mostrar información
    echo "============================================================"
    echo "  DESPLIEGUE COMPLETADO EXITOSAMENTE"
    echo "============================================================"
    echo ""
    echo "  Online Boutique:"
    echo "    URL: http://$FRONTEND_IP"
    echo ""
    echo "  Grafana (Dashboard de métricas):"
    echo "    URL: http://$GRAFANA_IP"
    echo "    Usuario: admin"
    echo "    Contraseña (base64): $GRAFANA_PASS"
    echo "    (Decodifica la contraseña manualmente con base64)"
    echo ""
    echo "  Queries recomendadas en Grafana:"
    echo "    CPU por pod:"
    echo "      sum(rate(container_cpu_usage_seconds_total{namespace=\"default\"}[5m])) by (pod)"
    echo "    Memoria por pod:"
    echo "      sum(container_memory_working_set_bytes{namespace=\"default\"}) by (pod)"
    echo ""
    echo "============================================================"
}

#------------------------------------------------------------------------------
# MAIN - Flujo principal del script
#------------------------------------------------------------------------------
main() {
    echo "============================================================"
    echo "  Intel DevOps Assessment - Automatización de Despliegue"
    echo "============================================================"
    echo ""

    install_dependencies
    check_prerequisites
    create_cluster
    deploy_boutique
    install_monitoring
    show_access_info
}

# Ejecutar función principal
main
