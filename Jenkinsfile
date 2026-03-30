pipeline {

agent {
label 'n8n'
}

environment {
AWS_REGION     = "us-east-1"
AWS_ACCOUNT_ID = "392746353565"
ECR_REPO_NAME  = "n8n-images"
ECR_REGISTRY   = "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_TAG      = "fcc_${BUILD_NUMBER}"
}

stages {

stage('Clone App Repo') {
  steps {
    container('git') {
      sshagent(['git-key']) {
        sh '''
          set -e

          mkdir -p /root/.ssh
          ssh-keyscan github.com >> /root/.ssh/known_hosts
          chmod 600 /root/.ssh/known_hosts

          rm -rf app
          git clone git@github.com:SanthaprakashMahendran/aws-testing-app.git app
        '''
      }
    }
  }
}

stage('Build & Push Image') {
  steps {
    container('kaniko') {
      sh '''
        set -e

        mkdir -p /kaniko/.docker

        cat <<EOF > /kaniko/.docker/config.json
{
  "credHelpers": {
    "${ECR_REGISTRY}": "ecr-login"
  }
}
EOF

        /kaniko/executor \
          --context app \
          --dockerfile app/Dockerfile \
          --destination ${ECR_REGISTRY}/${ECR_REPO_NAME}:${IMAGE_TAG}
      '''
    }
  }
}

stage('Update Dev & Prod Image Tag') {
  steps {
    sh """
      set -e
      sed -i 's/newTag: \".*\"/newTag: \"${IMAGE_TAG}\"/' overlays/dev/kustomization.yaml
      sed -i 's/newTag: \".*\"/newTag: \"${IMAGE_TAG}\"/' overlays/prod/kustomization.yaml
      echo "Updated dev and prod overlays to image tag: ${IMAGE_TAG}"
      git config user.email "jenkins@example.com" || true
      git config user.name "Jenkins" || true
      git add overlays/dev/kustomization.yaml overlays/prod/kustomization.yaml
      git diff --staged --quiet || git commit -m "Update dev and prod image tag to ${IMAGE_TAG}"
      git push || true
    """
  }
}

}

}



}

}
