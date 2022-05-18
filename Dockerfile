FROM --platform=linux/amd64 ubuntu:20.04

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential bison flex

ADD . /ceed
WORKDIR /ceed/src
RUN make ceed
