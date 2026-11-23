FROM ubuntu:22.04

# Install sysbench inside the container
RUN apt-get update && apt-get install -y sysbench

# Copy the existing benchmark script into the image
COPY benchmarks.sh /benchmarks.sh

# Execute the benchmark script when the container starts
CMD ["bash", "/benchmarks.sh"]
