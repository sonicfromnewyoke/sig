#!/usr/bin/env bash

# doc:
# this script will pull the latest change of the local repo
# and run the benchmark to collect metrics which are
# saved as results/output.json file. they are then
# moved to results/metrics/output-{commit}-{timestamp}.json
#
# these output files are then compared/visualized using the
# scripts/benchmark_server.py script

# now in the scripts/ dir
cd "$(dirname "$0")"
# now in the sig dir
cd ..

# pull the latest changes
git pull

git_commit=$(git rev-parse HEAD)
timestamp=$(date +%s)
result_dir="results/metrics"
result_file="${result_dir}/output-${git_commit}-*.json"

mkdir -p "$result_dir"

if ls $result_file 1> /dev/null 2>&1; then
  echo "Results for commit $git_commit already exist. Skipping benchmark."
else
  # Run the benchmark only if the result file doesn't exist
  zig build -Doptimize=ReleaseSafe -Dno-run benchmark
  ./zig-out/bin/benchmark --metrics -e -f all

  mv results/output.json "${result_dir}/output-${git_commit}-${timestamp}.json"
  echo "Benchmark results saved to ${result_dir}/output-${git_commit}-${timestamp}.json"
fi
