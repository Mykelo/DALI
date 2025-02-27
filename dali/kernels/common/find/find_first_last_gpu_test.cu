// Copyright (c) 2022, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "dali/kernels/common/find/find_first_last_gpu.cuh"
#include <gtest/gtest.h>
#include <vector>
#include "dali/core/cuda_event.h"
#include "dali/kernels/dynamic_scratchpad.h"
#include "dali/pipeline/data/views.h"
#include "dali/test/tensor_test_utils.h"
#include "dali/test/test_tensors.h"

namespace dali {
namespace kernels {
namespace find_first_last {
namespace test {

template <typename T>
struct threshold {
  T value_;
  explicit threshold(T value = 0) : value_(value) {}

  DALI_HOST_DEV DALI_FORCEINLINE bool operator()(T x) const noexcept {
    return x >= value_;
  }
};

template <typename T>
void SequentialFillBothEnds(T* data, int64_t data_len, T start_value) {
  auto value = start_value;
  int i = 0;
  int j = data_len - 1;
  for (; i < j; value++) {
    data[i++] = value;
    data[j--] = value;
  }
  if (i == j)
    data[i] = value;
}

class FindFirstLastTestGPU : public ::testing::Test {
 public:
  using T = float;
  using Idx = int64_t;
  TestTensorList<T> in_;
  TestTensorList<Idx> out_begin_;
  TestTensorList<Idx> out_length_;

  TestTensorList<Idx> ref_begin_;
  TestTensorList<Idx> ref_length_;

  using Predicate = threshold<T>;
  Predicate thresh{3};
  span<Predicate> predicates{&thresh, 1};

  void SetUp() final {
    int nsamples = 5;

    // 1500 chosen so that it doesn't fit one CUDA block (32*32)
    TensorListShape<> sh = {{5, }, {10, }, {9, }, {7, }, {1500, }};
    TensorListShape<0> out_sh(nsamples);
    in_.reshape(sh);
    out_begin_.reshape(out_sh);
    out_length_.reshape(out_sh);
    ref_begin_.reshape(out_sh);
    ref_length_.reshape(out_sh);

    for (int i = 0; i < nsamples; i++) {
      auto v = in_.cpu()[i];
      SequentialFillBothEnds(v.data, static_cast<int64_t>(v.shape.num_elements()), T(0));
    }

    // Threshold = 3
    // Input 0:  0 1 2 1 0
    //           ^^
    // Input 1:  0 1 2 3 4 4 3 2 1 0
    //                 ^     ^
    // Input 2:  0 1 2 3 4 3 2 1 0
    //                 ^   ^
    // Input 3:  0 1 2 3 2 1 0
    //                 ^^
    // Input 4:  0 1 2 3 4 5 ... 1494 1495 1496 1497 1498 1499
    //                 ^                   ^
    ref_begin_.cpu()[0].data[0] = 0;
    ref_length_.cpu()[0].data[0] = 0;

    ref_begin_.cpu()[1].data[0] = 3;
    ref_length_.cpu()[1].data[0] = 4;

    ref_begin_.cpu()[2].data[0] = 3;
    ref_length_.cpu()[2].data[0] = 3;

    ref_begin_.cpu()[3].data[0] = 3;
    ref_length_.cpu()[3].data[0] = 1;

    ref_begin_.cpu()[4].data[0] = 3;
    ref_length_.cpu()[4].data[0] = 1494;
  }

  void RunTest() {
    KernelContext ctx;
    ctx.gpu.stream = 0;
    DynamicScratchpad dyn_scratchpad({}, AccessOrder(ctx.gpu.stream));
    ctx.scratchpad = &dyn_scratchpad;

    auto out_begin = out_begin_.gpu().to_static<0>();
    auto out_length = out_length_.gpu().to_static<0>();
    auto in = in_.gpu().to_static<1>();

    FindFirstLastGPU kernel;
    kernel.template Run<T, Idx, Predicate, begin_length<Idx>>(ctx, out_begin, out_length, in,
                                                              predicates);
    CUDA_CALL(cudaStreamSynchronize(ctx.gpu.stream));

    int nsamples = in.size();
    for (int s = 0; s < nsamples; s++) {
      auto begin = out_begin_.cpu()[s].data[0];
      auto length = out_length_.cpu()[s].data[0];
      int64_t input_len = in_.cpu()[s].shape.num_elements();
      EXPECT_EQ(ref_begin_.cpu()[s].data[0], begin);
      EXPECT_EQ(ref_length_.cpu()[s].data[0], length);
    }
  }

  void RunPerf() {
    using T = float;
    using Idx = int64_t;
    int nsamples = 64;
    int n_iters = 1000;

    TensorListShape<0> out_sh(nsamples);
    TensorListShape<> sh(nsamples, 1);
    for (int s = 0; s < nsamples; s++) {
      if (s % 4 == 0)
        sh.tensor_shape_span(s)[0] = 16000 * 60;
      else if (s % 4 == 1)
        sh.tensor_shape_span(s)[0] = 16000 * 120;
      else if (s % 4 == 2)
        sh.tensor_shape_span(s)[0] = 16000 * 30;
      else if (s % 4 == 3)
        sh.tensor_shape_span(s)[0] = 16000 * 90;
    }

    TestTensorList<T> in_data;
    in_data.reshape(sh);

    TestTensorList<Idx> out_begin_, out_length_;
    out_begin_.reshape(out_sh);
    out_length_.reshape(out_sh);

    std::mt19937 rng;
    UniformRandomFill(in_data.cpu(), rng, 0.0, 1.0);

    CUDAEvent start = CUDAEvent::CreateWithFlags(0);
    CUDAEvent end = CUDAEvent::CreateWithFlags(0);
    double total_time_ms = 0;
    int64_t in_elems = in_data.cpu().shape.num_elements();
    int64_t in_bytes = in_elems * sizeof(T);
    int64_t out_elems = 2;
    int64_t out_bytes = out_elems * sizeof(int64_t);
    std::cout << "FindFirstLast GPU Perf test.\n"
              << "Input contains " << in_elems << " elements.\n";

    KernelContext ctx;
    ctx.gpu.stream = 0;

    auto out_begin = out_begin_.gpu().to_static<0>();
    auto out_length = out_length_.gpu().to_static<0>();
    auto in = in_data.gpu().to_static<1>();

    FindFirstLastGPU kernel;
    for (int i = 0; i < n_iters; ++i) {
      CUDA_CALL(cudaDeviceSynchronize());

      DynamicScratchpad dyn_scratchpad({}, AccessOrder(ctx.gpu.stream));
      ctx.scratchpad = &dyn_scratchpad;

      CUDA_CALL(cudaEventRecord(start));

      kernel.template Run<T, Idx, Predicate, begin_length<Idx>>(ctx, out_begin, out_length, in,
                                                                predicates);

      CUDA_CALL(cudaEventRecord(end));
      CUDA_CALL(cudaDeviceSynchronize());
      float time_ms;
      CUDA_CALL(cudaEventElapsedTime(&time_ms, start, end));
      total_time_ms += time_ms;
    }
    std::cout << "Bandwidth: " << n_iters * (in_bytes + out_bytes) / (total_time_ms * 1e6)
              << " GBs/sec" << std::endl;
  }
};

TEST_F(FindFirstLastTestGPU, RunTest) {
  this->RunTest();
}

TEST_F(FindFirstLastTestGPU, DISABLED_Benchmark) {
  this->RunPerf();
}

}  // namespace test
}  // namespace find_first_last
}  // namespace kernels
}  // namespace dali
