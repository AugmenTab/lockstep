FROM alpine:3.20
RUN apk add --no-cache build-base
WORKDIR /app
COPY . .
RUN make test
