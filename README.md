Usage: ./kata_longevity.sh <test-type> [arg_list] [options]
  Test Types:
    all               Run all tests in sequence, with default values.
    memory            Test set of memory requests. [100M, 1G, 2G...]
    cpu               Test set of cpu requests. [0.5, 1, 1.5 ...]
    emptydir          Test EmptyDir volume.
    emptydir-mem      Test EmptyDir Memory based volume.
    hostpath          Test HostPath Volume.
    scale             Test scaling to a set of replica numbers. [1, 2, 6 ...]
    volumes           Preform all volume types tests in sequence.

  options:
    -n, --namespace   Namespace to use
    -r, --rouds       Number of rounds per test
    -u, --url         Valid domain for testing webserver response
    -h, --help        Print this help message
