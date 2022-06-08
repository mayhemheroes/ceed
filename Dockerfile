FROM --platform=linux/amd64 ubuntu:20.04 as builder

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential bison flex

ADD . /ceed
WORKDIR /ceed/src
RUN make ceed

RUN mkdir -p /deps
RUN ldd /ceed/src/ceed | tr -s '[:blank:]' '\n' | grep '^/' | xargs -I % sh -c 'cp % /deps;'

FROM ubuntu:20.04 as package

COPY --from=builder /deps /deps
COPY --from=builder /ceed/src/ceed /ceed/src/ceed
ENV LD_LIBRARY_PATH=/deps
