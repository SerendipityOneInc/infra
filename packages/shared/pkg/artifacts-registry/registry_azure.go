package artifacts_registry

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/google/go-containerregistry/pkg/authn"
	"github.com/google/go-containerregistry/pkg/name"
	containerregistry "github.com/google/go-containerregistry/pkg/v1"
	"github.com/google/go-containerregistry/pkg/v1/remote"
	"github.com/google/go-containerregistry/pkg/v1/remote/transport"
)

// acrTokenScope is the AAD resource scope for an Azure Container Registry
// access token, exchanged below for an ACR refresh token.
const acrTokenScope = "https://containerregistry.azure.net/.default"

// acrNullGUIDUser is the fixed username docker/registry auth uses together with
// an ACR refresh token (the "az acr login" identity-token flow).
const acrNullGUIDUser = "00000000-0000-0000-0000-000000000000"

type AzureArtifactsRegistry struct {
	// loginServer is the ACR host, e.g. "e2bcore.azurecr.io".
	loginServer    string
	repositoryName string
	cred           azcore.TokenCredential
	httpClient     *http.Client
}

var (
	AzureLoginServerEnvVar    = "AZURE_CONTAINER_REGISTRY"
	AzureRepositoryNameEnvVar = "AZURE_DOCKER_REPOSITORY_NAME"
	AzureLoginServer          = os.Getenv(AzureLoginServerEnvVar)
	AzureRepositoryName       = os.Getenv(AzureRepositoryNameEnvVar)
)

var _ ArtifactsRegistry = (*AzureArtifactsRegistry)(nil)

func NewAzureArtifactsRegistry(_ context.Context) (*AzureArtifactsRegistry, error) {
	if AzureLoginServer == "" {
		return nil, fmt.Errorf("%s environment variable is not set", AzureLoginServerEnvVar)
	}
	if AzureRepositoryName == "" {
		return nil, fmt.Errorf("%s environment variable is not set", AzureRepositoryNameEnvVar)
	}

	// Managed Identity in prod, environment / Azure CLI in dev.
	cred, err := azidentity.NewDefaultAzureCredential(nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create default azure credential: %w", err)
	}

	return &AzureArtifactsRegistry{
		loginServer:    AzureLoginServer,
		repositoryName: AzureRepositoryName,
		cred:           cred,
		httpClient:     http.DefaultClient,
	}, nil
}

func (r *AzureArtifactsRegistry) GetTag(_ context.Context, _ string, buildId string) (string, error) {
	// ACR creates repositories lazily on push, so there is nothing to describe
	// (unlike ECR): the tag is just <loginServer>/<repository>:<buildId>.
	return fmt.Sprintf("%s/%s:%s", r.loginServer, r.repositoryName, buildId), nil
}

func (r *AzureArtifactsRegistry) GetImage(ctx context.Context, templateId string, buildId string, platform containerregistry.Platform) (containerregistry.Image, error) {
	imageUrl, err := r.GetTag(ctx, templateId, buildId)
	if err != nil {
		return nil, fmt.Errorf("failed to get image URL: %w", err)
	}

	ref, err := name.ParseReference(imageUrl)
	if err != nil {
		return nil, fmt.Errorf("invalid image reference: %w", err)
	}

	auth, err := r.getAuthToken(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to get auth: %w", err)
	}

	img, err := remote.Image(ref, remote.WithAuth(auth), remote.WithPlatform(platform), remote.WithContext(ctx))
	if err != nil {
		return nil, fmt.Errorf("error pulling image: %w", err)
	}

	return img, nil
}

func (r *AzureArtifactsRegistry) Delete(ctx context.Context, templateId string, buildId string) error {
	imageUrl, err := r.GetTag(ctx, templateId, buildId)
	if err != nil {
		return fmt.Errorf("failed to get image URL: %w", err)
	}

	ref, err := name.ParseReference(imageUrl)
	if err != nil {
		return fmt.Errorf("invalid image reference: %w", err)
	}

	auth, err := r.getAuthToken(ctx)
	if err != nil {
		return fmt.Errorf("failed to get auth: %w", err)
	}

	// The registry v2 API deletes manifests by digest, not tag, so resolve the
	// tag to its digest first.
	desc, err := remote.Head(ref, remote.WithAuth(auth), remote.WithContext(ctx))
	if err != nil {
		if isRegistryNotFound(err) {
			return ErrImageNotExists
		}

		return fmt.Errorf("failed to resolve image digest from acr: %w", err)
	}

	digestRef := ref.Context().Digest(desc.Digest.String())
	if err := remote.Delete(digestRef, remote.WithAuth(auth), remote.WithContext(ctx)); err != nil {
		if isRegistryNotFound(err) {
			return ErrImageNotExists
		}

		return fmt.Errorf("failed to delete image from acr: %w", err)
	}

	return nil
}

// getAuthToken exchanges an AAD access token (Managed Identity / DefaultAzureCredential)
// for an ACR refresh token, then returns it as basic auth under the fixed
// null-GUID username — the flow "az acr login" and docker-credential-acr use.
func (r *AzureArtifactsRegistry) getAuthToken(ctx context.Context) (authn.Authenticator, error) {
	aadToken, err := r.cred.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{acrTokenScope}})
	if err != nil {
		return nil, fmt.Errorf("failed to get aad token for acr: %w", err)
	}

	form := url.Values{}
	form.Set("grant_type", "access_token")
	form.Set("service", r.loginServer)
	form.Set("access_token", aadToken.Token)

	exchangeURL := fmt.Sprintf("https://%s/oauth2/exchange", r.loginServer)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, exchangeURL, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, fmt.Errorf("failed to build acr token exchange request: %w", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := r.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("acr token exchange request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("acr token exchange returned status %d", resp.StatusCode)
	}

	var body struct {
		RefreshToken string `json:"refresh_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return nil, fmt.Errorf("failed to decode acr token exchange response: %w", err)
	}
	if body.RefreshToken == "" {
		return nil, fmt.Errorf("acr token exchange returned an empty refresh token")
	}

	return &authn.Basic{
		Username: acrNullGUIDUser,
		Password: body.RefreshToken,
	}, nil
}

func isRegistryNotFound(err error) bool {
	var te *transport.Error
	if errors.As(err, &te) {
		return te.StatusCode == http.StatusNotFound
	}

	return false
}
