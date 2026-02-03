#!/bin/bash
#==============================================================================
# Intel DevOps Assessment - Script de Automatización
# Online Boutique Deployment + Monitoring (Prometheus & Grafana)
#==============================================================================
# Uso: bash deploy.sh
# Descripción: Automatiza el despliegue completo de la Online Boutique
#              en GKE junto con el stack de monitoreo.
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

#------------------------------------------------------------------------------
# PASO 1: Verificar prerrequisitos
#------------------------------------------------------------------------------
check_prerequisites() {
    log_info "=== PASO 1: Verificando prerrequisitos ==="

    # Verificar gcloud
    if ! command -v gcloud &> /dev/null; then
        log_error "gcloud no está instalado. Instálalo en: https://cloud.google.com/sdk/docs/install"
    fi
    log_success "gcloud encontrado"

    # Verificar kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl no está instalado. Instálalo en: https://kubernetes.io/docs/tasks/tools/"
    fi
    log_success "kubectl encontrado"

    # Verificar helm
    if ! command -v helm &> /dev/null; then
        log_error "helm no está instalado. Instálalo en: https://helm.sh/docs/intro/install/"
    fi
    log_success "helm encontrado"

    # Verificar git
    if ! command -v git &> /dev/null; then
        log_error "git no está instalado. Instálalo en: https://git-scm.com/downloads"
    fi
    log_success "git encontrado"

    # Verificar que el proyecto GCP existe
    if ! gcloud projects describe "$PROJECT_ID" &> /dev/null; then
        log_error "El proyecto '$PROJECT_ID' no existe en GCP. Créalo en la consola."
    fi
    log_success "Proyecto GCP '$PROJECT_ID' verificado"

    # Configurar el proyecto activo
    gcloud config set project "$PROJECT_ID"
    log_success "Proyecto activo configurado"
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
            --project="$PROJECT_ID"

        log_success "Clúster creado exitosamente"
    fi

    # Conectar kubectl al clúster
    log_info "Conectando kubectl al clúster..."
    gcloud container clusters get-credentials "$CLUSTER_NAME" \
        --zone="$ZONE" \
        --project="$PROJECT_ID"

    log_success "kubectl conectado al clúster"
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

    # Reducir recursos del loadgenerator para que pueda correr en el clúster
    log_info "Ajustando recursos del loadgenerator..."
    sed -i 's/cpu: 300m/cpu: 50m/g' kustomize/base/loadgenerator.yaml
    sed -i 's/memory: 256Mi/memory: 64Mi/g' kustomize/base/loadgenerator.yaml
    sed -i 's/cpu: 500m/cpu: 100m/g' kustomize/base/loadgenerator.yaml
    sed -i 's/memory: 512Mi/memory: 128Mi/g' kustomize/base/loadgenerator.yaml

    # Reducir requests de CPU de todos los servicios para evitar insuficiencia de recursos
    log_info "Ajustando recursos de los servicios..."
    for file in kustomize/base/*.yaml; do
        sed -i '/requests:/,/memory:/{s/cpu: [0-9]*m/cpu: 50m/}' "$file"
    done

    # Desplegar usando kustomize
    log_info "Desplegando Online Boutique..."
    kubectl apply -k ./kustomize/

    # Esperar a que los pods estén listos (12 pods en total)
    wait_for_pods "default" 12

    cd ..
}

#------------------------------------------------------------------------------
# PASO 4: Instalar Prometheus + Grafana (monitoreo)
#------------------------------------------------------------------------------
install_monitoring() {
    log_info "=== PASO 4: Instalando stack de monitoreo ==="

    # Crear namespace de monitoreo
    kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Agregar repositorio de Helm de prometheus-community
    log_info "Agregando repositorio de Helm..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    # Instalar kube-prometheus-stack (incluye Prometheus + Grafana)
    if helm list -n "$MONITORING_NAMESPACE" | grep -q "prometheus"; then
        log_warn "Prometheus ya está instalado. Se salta la instalación."
    else
        log_info "Instalando kube-prometheus-stack..."
        helm install prometheus prometheus-community/kube-prometheus-stack \
            --namespace "$MONITORING_NAMESPACE"
        log_success "kube-prometheus-stack instalado"
    fi

    # Exponer Grafana con IP pública (LoadBalancer)
    log_info "Exponiendo Grafana con IP pública..."
    kubectl patch service prometheus-grafana \
        --namespace "$MONITORING_NAMESPACE" \
        -p '{"spec":{"type":"LoadBalancer"}}'

    # Esperar a que el LoadBalancer tenga IP externa
    log_info "Esperando IP externa de Grafana..."
    local timeout=120
    local elapsed=0
    while [ $elapsed -lt $timeout ]; do
        GRAFANA_IP=$(kubectl get service prometheus-grafana \
            --namespace "$MONITORING_NAMESPACE" \
            -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>/dev/null)
        if [ -n "$GRAFANA_IP" ]; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if [ -z "$GRAFANA_IP" ]; then
        log_warn "No se pudo obtener la IP de Grafana automáticamente."
    fi
}

#------------------------------------------------------------------------------
# PASO 5: Obtener información de acceso
#------------------------------------------------------------------------------
print_access_info() {
    log_info "=== PASO 5: Información de acceso ==="

    # IP del frontend de la Online Boutique
    FRONTEND_IP=$(kubectl get service frontend-external \
        -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>/dev/null)

    # IP de Grafana
    GRAFANA_IP=$(kubectl get service prometheus-grafana \
        --namespace "$MONITORING_NAMESPACE" \
        -o jsonpath="{.status.loadBalancer.ingress[0].ip}" 2>/dev/null)

    # Contraseña de Grafana (codificada en base64)
    GRAFANA_PASS_B64=$(kubectl get secret prometheus-grafana \
        --namespace "$MONITORING_NAMESPACE" \
        -o jsonpath="{.data.admin-password}" 2>/dev/null)

    echo ""
    echo -e "${GREEN}============================================================${NC}"
    echo -e "${GREEN}  DESPLIEGUE COMPLETADO EXITOSAMENTE${NC}"
    echo -e "${GREEN}============================================================${NC}"
    echo ""
    echo -e "  ${BLUE}Online Boutique:${NC}"
    echo "    URL: http://$FRONTEND_IP"
    echo ""
    echo -e "  ${BLUE}Grafana (Dashboard de métricas):${NC}"
    echo "    URL: http://$GRAFANA_IP"
    echo "    Usuario: admin"
    echo "    Contraseña (base64): $GRAFANA_PASS_B64"
    echo "    (Decodifica la contraseña manualmente con base64)"
    echo ""
    echo -e "  ${BLUE}Queries recomendadas en Grafana:${NC}"
    echo "    CPU por pod:"
    echo "      sum(rate(container_cpu_usage_seconds_total{namespace=\"default\"}[5m])) by (pod)"
    echo "    Memoria por pod:"
    echo "      sum(container_memory_working_set_bytes{namespace=\"default\"}) by (pod)"
    echo ""
    echo -e "${GREEN}============================================================${NC}"
}

#------------------------------------------------------------------------------
# MAIN: Ejecución principal del script
#------------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BLUE}============================================================${NC}"
    echo -e "${BLUE}  Intel DevOps Assessment - Automatización de Despliegue${NC}"
    echo -e "${BLUE}============================================================${NC}"
    echo ""

    check_prerequisites
    create_cluster
    deploy_boutique
    install_monitoring
    print_access_info
}

# Ejecutar
main
