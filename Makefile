preview:
	npx zenn preview
cloudrun:
	gcloud config set project $(GCLOUD_PROJECT)
	$(eval service_name := zenn-preview)
	gcloud builds submit --config=cloudbuild.yaml --substitutions=_GCLOUD_PROJECT="$(GCLOUD_PROJECT)",_SERVICE_NAME="$(service_name)"
