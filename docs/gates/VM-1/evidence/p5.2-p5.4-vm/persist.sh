test -x /work/repo/build/test && echo build-artifact-kept
docker image inspect capsule-test-app >/dev/null 2>&1 && echo docker-image-kept
docker image inspect redis:7-alpine >/dev/null 2>&1 && echo pulled-image-kept
command -v tree >/dev/null && echo installed-package-kept
