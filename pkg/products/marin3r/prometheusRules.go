package marin3r

import (
	"fmt"
	"github.com/integr8ly/integreatly-operator/pkg/resources"
	l "github.com/integr8ly/integreatly-operator/pkg/resources/logger"
	monitoringv1 "github.com/prometheus-operator/prometheus-operator/pkg/apis/monitoring/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
)

func (r *Reconciler) newAlertReconciler(logger l.Logger, installType string) resources.AlertReconciler {
	installationName := resources.InstallationNames[installType]

	observabilityConfig, err := r.ConfigManager.ReadObservability()
	if err != nil {
		logger.Warning("failed to get observability config")
		return nil
	}

	namespace := observabilityConfig.GetNamespace()
	operatorNamespace := observabilityConfig.GetNamespace()
	alertNamePrefix := "marin3r-"
	operatorAlertNamePrefix := "marin3r-operator-"

	return &resources.AlertReconcilerImpl{
		Installation: r.installation,
		Log:          logger,
		ProductName:  "Marin3r",
		Alerts: []resources.AlertConfiguration{
			{
				AlertName: alertNamePrefix + "ksm-endpoint-alerts",
				GroupName: "marin3r-endpoint.rules",
				Namespace: namespace,
				Rules: []monitoringv1.Rule{
					{
						Alert: "Marin3rDiscoveryServiceEndpointDown",
						Annotations: map[string]string{
							"sop_url": resources.SopUrlEndpointAvailableAlert,
							"message": fmt.Sprintf("No {{  $labels.endpoint  }} endpoints in namespace %s. Expected at least 1.", r.Config.GetNamespace()),
						},
						Expr:   intstr.FromString(fmt.Sprintf("kube_endpoint_address_available{endpoint='marin3r-instance', namespace='%s'} < 1", r.Config.GetNamespace())),
						For:    "5m",
						Labels: map[string]string{"severity": "warning", "product": installationName},
					},
					{
						Alert: "Marin3rRateLimitServiceEndpointDown",
						Annotations: map[string]string{
							"sop_url": resources.SopUrlEndpointAvailableAlert,
							"message": fmt.Sprintf("No {{  $labels.endpoint  }} endpoints in namespace %s. Expected at least 1.", r.Config.GetNamespace()),
						},
						Expr:   intstr.FromString(fmt.Sprintf("kube_endpoint_address_available{endpoint='ratelimit', namespace='%s'} < 1", r.Config.GetNamespace())),
						For:    "5m",
						Labels: map[string]string{"severity": "warning", "product": installationName},
					},
				},
			},
			{
				AlertName: operatorAlertNamePrefix + "ksm-endpoint-alerts",
				GroupName: "marin3r-operator-endpoint.rules",
				Namespace: operatorNamespace,
				Rules: []monitoringv1.Rule{
					{
						Alert: "Marin3rOperatorRhmiRegistryCsServiceEndpointDown",
						Annotations: map[string]string{
							"sop_url": resources.SopUrlEndpointAvailableAlert,
							"message": fmt.Sprintf("No {{  $labels.endpoint  }} endpoints in namespace %s. Expected at least 1.", r.Config.GetOperatorNamespace()),
						},
						Expr:   intstr.FromString(fmt.Sprintf("kube_endpoint_address_available{endpoint='rhmi-registry-cs', namespace='%s'} < 1", r.Config.GetOperatorNamespace())),
						For:    "8m",
						Labels: map[string]string{"severity": "warning", "product": installationName},
					},
				},
			},
			{
				AlertName: operatorAlertNamePrefix + "ksm-marin3r-alerts",
				GroupName: "general.rules",
				Namespace: operatorNamespace,
				Rules: []monitoringv1.Rule{
					{
						Alert: "Marin3rOperatorPod",
						Annotations: map[string]string{
							"sop_url": resources.SopUrlAlertsAndTroubleshooting,
							"message": "Marin3r operator has no pods in ready state.",
						},
						Expr:   intstr.FromString(fmt.Sprintf("sum(kube_pod_status_ready{condition='true',namespace='%[1]v', pod=~'marin3r-controller-manager.*'}  * on(pod, namespace) group_left() kube_pod_status_phase{phase='Running'}) < 1", r.Config.GetOperatorNamespace())),
						For:    "5m",
						Labels: map[string]string{"severity": "warning", "product": installationName},
					},
				},
			},
			{
				AlertName: alertNamePrefix + "ksm-marin3r-alerts",
				GroupName: "general.rules",
				Namespace: namespace,
				Rules: []monitoringv1.Rule{
					{
						Alert: "Marin3rWebhookPod",
						Annotations: map[string]string{
							"sop_url": resources.SopUrlAlertsAndTroubleshooting,
							"message": "Marin3r has no webhook pods in ready state.",
						},
						Expr:   intstr.FromString(fmt.Sprintf("sum(kube_pod_status_ready{condition='true',namespace='%[1]v', pod=~'marin3r-controller-webhook.*'}  * on(pod, namespace) group_left() kube_pod_status_phase{phase='Running'}) < 1", r.Config.GetOperatorNamespace())),
						For:    "5m",
						Labels: map[string]string{"severity": "warning", "product": installationName},
					},
					{
						Alert: "Marin3rRateLimitPod",
						Annotations: map[string]string{
							"sop_url": resources.SopUrlAlertsAndTroubleshooting,
							"message": "Marin3r Rate Limit has no pods in a ready state.",
						},
						Expr:   intstr.FromString(fmt.Sprintf("sum(kube_pod_status_ready{condition='true',namespace='%[1]v', pod=~'ratelimit.*'}  * on(pod, namespace) group_left() kube_pod_status_phase{phase='Running'}) < 1", r.Config.GetNamespace())),
						For:    "5m",
						Labels: map[string]string{"severity": "warning", "product": installationName},
					},
				},
			},
		},
	}
}
