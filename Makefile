build:
	docker pull adoptopenjdk/openjdk11:debian
	source ./version && DOCKER_BUILDKIT=0 docker build -t eugenmayer/rundeck:"$${VERSION}" --build-arg RUNDECK_VERSION="$${VERSION}" . 

push:
	source ./version && docker push eugenmayer/rundeck:"$${VERSION}"
