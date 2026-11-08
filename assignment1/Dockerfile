FROM ubuntu:22.04

# Install sysbench inside the container
#RUN apt update && apt install -y sysbench

# Copy the existing benchmark script into the image
#COPY benchmarks.sh /benchmarks.sh

# Execute the benchmark script when the container starts
#RUN chmod +x /benchmarks.sh
#CMD ["/benchmarks.sh"]

FROM ubuntu:22.04

RUN apt-get update && apt-get install -y sysbench

COPY benchmarks.sh /benchmarks.sh

CMD ["bash", "/benchmarks.sh"]
