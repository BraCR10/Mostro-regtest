FROM golang:1.21-alpine AS builder

RUN apk add --no-cache git gcc musl-dev linux-headers

RUN git clone https://github.com/nbd-wtf/satdress.git /satdress

WORKDIR /satdress
RUN go build -o satdress .

FROM alpine:3.18

COPY --from=builder /satdress/satdress /usr/local/bin/satdress

EXPOSE 17422

CMD ["satdress"]
