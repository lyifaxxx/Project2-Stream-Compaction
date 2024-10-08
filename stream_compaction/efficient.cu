#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "efficient.h"

#define blockSize 256
#define RECURSIVE_SCAN 0

namespace StreamCompaction {
    namespace Efficient {
        using StreamCompaction::Common::PerformanceTimer;
        PerformanceTimer& timer()
        {
            static PerformanceTimer timer;
            return timer;
        }


		// up-sweep kernel
        __global__ void kernUpSweep(int n, int* odata, int* idata, int t) {
            int index = threadIdx.x + (blockIdx.x * blockDim.x);
            if (index >= n) {
                return;
            }
#if RECURSIVE_SCAN
			// exclusive scan
			odata[index] = (index > 0) ? idata[index - 1] : 0;
			__syncthreads();
			// upsweep
            for (int d = 0; d <= t; ++d) {
                int offset = 1 << (d + 1);
				int ai = index + offset - 1;
				int bi = index + (offset / 2) - 1;
                if (index < n && (index % offset) == 0) {
                    odata[ai] += odata[bi];
                }

                __syncthreads();
            }
#else
			int offset = 1 << (t + 1); // 2^(d + 1)
			int ai = index + offset - 1;
			int bi = index + (offset >> 1) - 1;
			if ((index & (offset - 1)) == 0) {
				idata[ai] += idata[bi];
			}
#endif
		}

        // down-sweep kernel
		__global__ void kernDownSweep(int n, int* odata, const int* idata, int t) {
			int index = threadIdx.x + (blockIdx.x * blockDim.x);
#if RECURSIVE_SCAN
			if (index >= 1 << (t + 1)) {
				return;
			}
			// exclusive scan
			odata[index] = (index > 0) ? idata[index - 1] : 0;
			__syncthreads();
			// downsweep
			if (index == 0) {
				odata[n - 1] = 0;
			}
			for (int d = t; d >= 0; --d) {
				int offset = 1 << (d + 1);
				int ai = index + offset - 1;
				int bi = index + (offset / 2) - 1;
				if (index < n && (index % offset) == 0) {
					int temp = odata[bi];
					odata[bi] = odata[ai];
					odata[ai] += temp;
				}

				__syncthreads();
			}
#else	
			if (index >= n) {
				return;
			}

			__syncthreads();			

			int offset = 1 << (t + 1);
			int ai = index + offset - 1;
			int bi = index + (offset >> 1) - 1;
			if ((index & (offset - 1)) == 0) {
				int temp = odata[bi];
				odata[bi] = odata[ai];
				odata[ai] += temp;
			}

			__syncthreads();


#endif 
		}

		__global__ void kernUpSweep_opt(int n, int* idata, int d) {
			int index = threadIdx.x + (blockIdx.x * blockDim.x);
			if (index >= n) {
				return;
			}
			int offset = 1 << (d + 1);
			index <<= (d + 1);
			idata[index + offset - 1] += idata[index + (offset >> 1) - 1];
		}

		__global__ void kernDownSweep_opt(int n, int* idata, int d) {
			int index = threadIdx.x + (blockIdx.x * blockDim.x);
			if (index >= n) {
				return;
			}
			int offset = 1 << (d + 1);
			index <<= (d + 1);
			int temp = idata[index + (offset >> 1) - 1];
			idata[index + (offset >> 1) - 1] = idata[index + offset - 1];
			idata[index + offset - 1] += temp;
		}


		// up sweep + down aweep
		__global__ void kernScan(int n, int* odata, const int* idata, int t) {
			int index = threadIdx.x + (blockIdx.x * blockDim.x);
			int paddedSize = 1 << (t + 1);
			if (index >= paddedSize) {
				return;
			}
			// exclusive scan
			//odata[index] = (index > 0) ? idata[index - 1] : 0;
			//odata[index] = idata[index];
			odata[index] = (index >= n) ? 0 : idata[index];
			__syncthreads();
			// upsweep
			for (int d = 0; d <= t; ++d) {
				int offset = 1 << (d + 1);
				int ai = index + offset - 1;
				int bi = index + (offset >> 1) - 1;
				if (index < paddedSize && ((index & (offset - 1)) == 0)) {
					odata[ai] += odata[bi];
				}

				__syncthreads();
			}
			// downsweep
			if (index == 0) {
				odata[paddedSize - 1] = 0;
			}
			
			for (int d = t; d >= 0; --d) {
				int offset = 1 << (d + 1);
				int ai = index + offset - 1;
				int bi = index + (offset >> 1) - 1;
				if (index < paddedSize && ((index & (offset - 1)) == 0)) {
					int temp = odata[bi];
					odata[bi] = odata[ai];
					odata[ai] += temp;
				}

				__syncthreads();
			}
		}


        /**
         * Performs prefix-sum (aka scan) on idata, storing the result into odata.
         */
        void scan(int n, int *odata, const int *idata) {
            
            // TODO
			int t = ilog2ceil(n) - 1;
			int peddedSize = 1 << (t + 1);
			//const int blockSize = 128;
			int numBlocks = (peddedSize + blockSize - 1) / blockSize;
			dim3 fullBlocksPerGrid(numBlocks);
			
			/*printf("log2_n - 1: %d\n", t);
			printf("array size: %d; pedded size: %d\n", n, peddedSize);
			printf("block numbers: %d\n", numBlocks);*/
			// call kernel
			int* dev_idata;
			int* dev_odata;
			cudaMalloc((void**)&dev_idata, peddedSize * sizeof(int));
			cudaMalloc((void**)&dev_odata, peddedSize * sizeof(int));
			cudaMemset(dev_odata, 0, peddedSize * sizeof(int));
			cudaMemset(dev_idata, 0, peddedSize * sizeof(int));
			cudaMemcpy(dev_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
			cudaMemcpy(dev_odata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
           
			timer().startGpuTimer();

#if RECURSIVE_SCAN
            //kernUpSweep << <1, n >> > (n, dev_odata, dev_idata, t);
			//kernDownSweep << <1, n >> > (n, dev_odata, dev_idata, t);
			//kernScan << <fullBlocksPerGrid, blockSize >> > (n, dev_odata, dev_idata, t); // arbitrary block size
			kernScan << <1, n >> > (n, dev_odata, dev_idata, t);
#else
			
			// up-sweep
			for (int d = 0; d <= t; ++d) {
				kernUpSweep << <numBlocks, blockSize >> > (peddedSize, dev_odata, dev_idata, d);
			}
			// down sweep
			// set last element to 0
			
			cudaMemset(dev_idata + peddedSize - 1, 0, sizeof(int));
			for (int d = t; d >= 0; d--) {				
				kernDownSweep << <numBlocks, blockSize >> > (peddedSize, dev_idata, dev_idata, d);
			}

#endif
			timer().endGpuTimer();
			cudaMemcpy(odata, dev_idata, n * sizeof(int), cudaMemcpyDeviceToHost);
			cudaFree(dev_idata);
			cudaFree(dev_odata);            
        }

		// dynamic block number
		void scan_opt(int n, int* odata, const int* idata) {
			int t = ilog2ceil(n) - 1;
			int peddedSize = 1 << (t + 1);
			int numBlocks = (peddedSize + blockSize - 1) / blockSize;
			dim3 fullBlocksPerGrid(numBlocks);

			// call kernel
			int* dev_idata;
			cudaMalloc((void**)&dev_idata, peddedSize * sizeof(int));
			cudaMemset(dev_idata, 0, peddedSize * sizeof(int));
			cudaMemcpy(dev_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);

			timer().startGpuTimer();

			// up-sweep
			for (int d = 0; d <= t; d++) {
				int offset = 1 << (d + 1);
				int activeThreads = peddedSize / offset;
				numBlocks = (activeThreads + offset - 1) / offset;
				dim3 fullBlocksPerGrid(numBlocks);
				kernUpSweep_opt << <numBlocks, blockSize >> > (activeThreads, dev_idata, d);
				cudaDeviceSynchronize();
			}
			// down sweep
			// set last element to 0
			cudaMemset(dev_idata + peddedSize - 1, 0, sizeof(int));
			for (int d = t; d >= 0; d--) {
				int offset = 1 << (d + 1);
				int activeThreads = peddedSize / offset;
				numBlocks = (activeThreads + offset - 1) / offset;
				dim3 fullBlocksPerGrid(numBlocks);
				kernDownSweep_opt << <numBlocks, blockSize >> > (activeThreads, dev_idata, d);
				cudaDeviceSynchronize();
			}

			timer().endGpuTimer();
			cudaMemcpy(odata, dev_idata, n * sizeof(int), cudaMemcpyDeviceToHost);
			cudaFree(dev_idata);

		}



        /**
         * Performs stream compaction on idata, storing the result into odata.
         * All zeroes are discarded.
         *
         * @param n      The number of elements in idata.
         * @param odata  The array into which to store elements.
         * @param idata  The array of elements to compact.
         * @returns      The number of elements remaining after compaction.
         */
        int compact(int n, int *odata, const int *idata) {
            //timer().startGpuTimer();
            // TODO
			// compute bool array
			int t = ilog2ceil(n) - 1;
			int peddedSize = 1 << (t + 1);
			int numBlocks = (peddedSize + blockSize - 1) / blockSize;
			dim3 fullBlocksPerGrid(numBlocks);
			int* dev_bools;
			int* dev_idata;
			int* dev_indices;
			int* dev_odata;
			int* bools = new int[peddedSize];
			int* indices = new int[peddedSize];
			cudaMalloc((void**)&dev_bools, peddedSize * sizeof(int));
			cudaMalloc((void**)&dev_idata, peddedSize * sizeof(int));
			cudaMalloc((void**)&dev_indices, peddedSize * sizeof(int));
			cudaMalloc((void**)&dev_odata, peddedSize * sizeof(int));
			cudaMemcpy(dev_idata, idata, n * sizeof(int), cudaMemcpyHostToDevice);
			cudaMemset(dev_bools, 0, peddedSize * sizeof(int));
			cudaMemset(dev_indices, 0, peddedSize * sizeof(int));
			StreamCompaction::Common::kernMapToBoolean << <numBlocks, blockSize >> > (peddedSize, dev_bools, dev_idata);
			// scan
#if 1
			kernScan << <1, n >> > (n, dev_indices, dev_bools, t);
			// scatter
			StreamCompaction::Common::kernScatter << <1, n >> > (n, dev_odata, dev_idata, dev_bools, dev_indices);
			cudaMemcpy(odata, dev_odata, n * sizeof(int), cudaMemcpyDeviceToHost);
			cudaMemcpy(bools, dev_bools, n * sizeof(int), cudaMemcpyDeviceToHost);
			cudaMemcpy(indices, dev_indices, n * sizeof(int), cudaMemcpyDeviceToHost);
			int count = bools[n - 1] ? indices[n - 1] + 1 : indices[n - 1];
			cudaFree(dev_bools);
			cudaFree(dev_idata);
			cudaFree(dev_indices);
			cudaFree(dev_odata);
			delete[] bools;
			delete[] indices;
#else
			// up-sweep
			int* temp = new int[peddedSize];
			dev_odata = dev_bools;
			for (int i = 0; i <= t; i++) {
				//int offset = 1 << (i + 1);
				//int numBlocks = (n + offset - 1) / offset;
				//dim3 fullBlocksPerGrid(numBlocks);
				kernUpSweep << <fullBlocksPerGrid, blockSize >> > (peddedSize, dev_odata, dev_odata, i);
			}

			// set last element to 0
			cudaMemset(dev_odata + peddedSize - 1, 0, sizeof(int));
			// down-sweep
			for (int i = t; i >= 0; i--) {
				//int offset = 1 << (i + 1);
				//int numBlocks = (n + offset - 1) / offset;
				//dim3 fullBlocksPerGrid(numBlocks);
				kernDownSweep << <fullBlocksPerGrid, blockSize >> > (peddedSize, dev_odata, dev_odata, i);
			}
			dev_indices = dev_odata;
			cudaMemset(dev_odata, 0, peddedSize * sizeof(int));

			// scatter
			StreamCompaction::Common::kernScatter << <numBlocks, blockSize >> > (peddedSize, dev_odata, dev_idata, dev_bools, dev_indices);
			cudaMemcpy(odata, dev_odata, n * sizeof(int), cudaMemcpyDeviceToHost);
			cudaMemcpy(bools, dev_bools, n * sizeof(int), cudaMemcpyDeviceToHost);
			cudaMemcpy(indices, dev_indices, n * sizeof(int), cudaMemcpyDeviceToHost);
			int count = bools[n - 1] ? indices[n - 1] : indices[n - 1];

			cudaFree(dev_bools);
			cudaFree(dev_idata);
			cudaFree(dev_indices);
			cudaFree(dev_odata);
			delete[] bools;
			delete[] indices;
			delete[] temp;
			printf("work-efficient compact: %d\n", count);
#endif


            //timer().endGpuTimer();
            return count;
        }
    }
}
