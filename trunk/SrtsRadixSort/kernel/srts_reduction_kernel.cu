/**
 * Copyright 2010 Duane Merrill
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * 
 * 
 * 
 * AUTHORS' REQUEST: 
 * 
 * 		If you use|reference|benchmark this code, please cite our Technical 
 * 		Report (http://www.cs.virginia.edu/~dgm4d/papers/RadixSortTR.pdf):
 * 
 * 		Duane Merrill and Andrew Grimshaw, "Revisiting Sorting for GPGPU 
 * 		Stream Architectures," University of Virginia, Department of 
 * 		Computer Science, Charlottesville, VA, USA, Technical Report 
 * 		CS2010-03, 2010.
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 * Thanks!
 */


//------------------------------------------------------------------------------
// RakingReduction
//------------------------------------------------------------------------------

#ifndef _SRTS_RADIX_SORT_REDUCTION_KERNEL_H_
#define _SRTS_RADIX_SORT_REDUCTION_KERNEL_H_

#include <kernel/srts_radixsort_kernel_common.cu>


//------------------------------------------------------------------------------
// Defines
//------------------------------------------------------------------------------

#define BYTE_ENCODE_SHIFT		0x3


//------------------------------------------------------------------------------
// Cycle-processing Routines
//------------------------------------------------------------------------------

__device__ inline unsigned int DecodeInt(unsigned int encoded, unsigned int quad_byte){
	return (encoded >> quad_byte) & 0xff;		// shift right 8 bits per digit and return rightmost 8 bits
}


__device__ inline unsigned int EncodeInt(unsigned int count, unsigned int quad_byte) {
	return count << quad_byte;					// shift left 8 bits per digit
}


template <typename K, unsigned long long RADIX_DIGITS, int BIT>
__device__ inline void DecodeDigit(
	K key, 
	unsigned int &lane, 
	unsigned int &quad_shift) 
{
	const K DIGIT_MASK = RADIX_DIGITS - 1;
	lane = (key & (DIGIT_MASK << BIT)) >> (BIT + 2);
	
	const K QUAD_MASK = (RADIX_DIGITS < 4) ? 0x1 : 0x3;
	quad_shift = MagnitudeShift<K, BYTE_ENCODE_SHIFT - BIT>(key & (QUAD_MASK << BIT));
}


template <unsigned int RADIX_DIGITS, unsigned int SCAN_LANES, unsigned int LANES_PER_WARP, unsigned int BIT, bool FINAL_REDUCE>
__device__ inline void ReduceEncodedCounts(
	unsigned int local_counts[LANES_PER_WARP][4],
	unsigned int encoded_carry[SCAN_LANES][SRTS_THREADS]) 
{
	const unsigned int LOG_PARTIALS_PER_THREAD = SRTS_LOG_THREADS - LOG_WARP_THREADS;
	const unsigned int PARTIALS_PER_THREAD = 1 << LOG_PARTIALS_PER_THREAD;
	
	unsigned int encoded;
	unsigned int idx = threadIdx.x & (WARP_THREADS - 1);
	
	
	__syncthreads();

	#pragma unroll
	for (int j = 0; j < (int) LANES_PER_WARP; j++) {
		
		unsigned int warp_id = (threadIdx.x >> LOG_WARP_THREADS) + (j * SRTS_WARPS);
		if (warp_id < SCAN_LANES) {

			// rest of my elements
			#pragma unroll
			for (int i = 0; i < (int) PARTIALS_PER_THREAD; i++) {
				encoded = encoded_carry[warp_id][idx + (i * WARP_THREADS)];		
				local_counts[j][0] += DecodeInt(encoded, 0u << BYTE_ENCODE_SHIFT);
				local_counts[j][1] += DecodeInt(encoded, 1u << BYTE_ENCODE_SHIFT);
				local_counts[j][2] += DecodeInt(encoded, 2u << BYTE_ENCODE_SHIFT);
				local_counts[j][3] += DecodeInt(encoded, 3u << BYTE_ENCODE_SHIFT);
			}
			
			if (FINAL_REDUCE) {
				// reduce all four packed fields, leaving them in the first four elements of our row
				WarpReduce(idx, &encoded_carry[warp_id][0], local_counts[j][0]);
				WarpReduce(idx, &encoded_carry[warp_id][1], local_counts[j][1]);
				WarpReduce(idx, &encoded_carry[warp_id][2], local_counts[j][2]);
				WarpReduce(idx, &encoded_carry[warp_id][3], local_counts[j][3]);
			}
		}
	}	

	__syncthreads();
	
}
	

template <typename K, unsigned int RADIX_DIGITS, unsigned int SCAN_LANES, unsigned int BIT, typename PreprocessFunctor>
__device__ inline void Bucket(
	K input, 
	unsigned int encoded_carry[SCAN_LANES][SRTS_THREADS],
	PreprocessFunctor preprocess = PreprocessFunctor()) 
{
	unsigned int lane, quad_shift;
	preprocess(input);
	DecodeDigit<K, RADIX_DIGITS, BIT>(input, lane, quad_shift);
	encoded_carry[lane][threadIdx.x] += EncodeInt(1, quad_shift);
}


template <typename K, unsigned int RADIX_DIGITS, unsigned int SCAN_LANES, unsigned int BIT, typename PreprocessFunctor, unsigned int CYCLES>
__device__ inline void BlockOfLoads4(
	K *d_in_keys,
	unsigned int &offset,
	unsigned int encoded_carry[SCAN_LANES][SRTS_THREADS]) 
{
	K keys[4];

	#pragma unroll
	for (int i = 0; i < (int) CYCLES; i += 4) {
		
		keys[0] = d_in_keys[offset + (SRTS_THREADS * (i + 0)) + threadIdx.x];
		keys[1] = d_in_keys[offset + (SRTS_THREADS * (i + 1)) + threadIdx.x];
		keys[2] = d_in_keys[offset + (SRTS_THREADS * (i + 2)) + threadIdx.x];
		keys[3] = d_in_keys[offset + (SRTS_THREADS * (i + 3)) + threadIdx.x];

		if (FERMI(__CUDA_ARCH__)) __syncthreads();
		
		Bucket<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor>(keys[0], encoded_carry);
		Bucket<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor>(keys[1], encoded_carry);
		Bucket<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor>(keys[2], encoded_carry);
		Bucket<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor>(keys[3], encoded_carry);
	}

	offset += SRTS_THREADS * CYCLES;
}


template <typename K, unsigned int RADIX_DIGITS, unsigned int SCAN_LANES, unsigned int BIT, typename PreprocessFunctor, unsigned int CYCLES>
__device__ inline void BlockOfLoads(
	K *d_in_keys,
	unsigned int &offset,
	unsigned int encoded_carry[SCAN_LANES][SRTS_THREADS]) 
{
	#pragma unroll
	for (int i = 0; i < (int) CYCLES; i++) {
	
		Bucket<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor>(
			d_in_keys[offset + (SRTS_THREADS * i) + threadIdx.x], 
			encoded_carry);
	}
	
	offset += SRTS_THREADS * CYCLES;
}


template <unsigned int SCAN_LANES>
__device__ inline void ResetEncodedCarry(
	unsigned int encoded_carry[SCAN_LANES][SRTS_THREADS])
{
	#pragma unroll
	for (int SCAN_LANE = 0; SCAN_LANE < (int) SCAN_LANES; SCAN_LANE++) {
		encoded_carry[SCAN_LANE][threadIdx.x] = 0;
	}
}


template <typename K, unsigned int RADIX_DIGITS, unsigned int SCAN_LANES, unsigned int LANES_PER_WARP, unsigned int BIT, typename PreprocessFunctor>
__device__ inline unsigned int ProcessLoads(
	K *d_in_keys,
	unsigned int loads,
	unsigned int &offset,
	unsigned int encoded_carry[SCAN_LANES][SRTS_THREADS],
	unsigned int local_counts[LANES_PER_WARP][4])
{
	// Unroll batches of loads with occasional reduction to avoid overflow
	while (loads >= 252) {
	
		BlockOfLoads4<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 252>(d_in_keys, offset, encoded_carry);
		loads -= 252;

		// Reduce int local count registers to prevent overflow
		ReduceEncodedCounts<RADIX_DIGITS, SCAN_LANES, LANES_PER_WARP, BIT, false>(
				local_counts, 
				encoded_carry);
		
		// Reset encoded counters
		ResetEncodedCarry<SCAN_LANES>(encoded_carry);
	} 
	
	unsigned int retval = loads;
	
	// Wind down loads in decreasing batch sizes
	if (loads >= 128) {
		BlockOfLoads4<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 128>(d_in_keys, offset, encoded_carry);
		loads -= 128;
	}
	if (loads >= 64) {
		BlockOfLoads4<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 64>(d_in_keys, offset, encoded_carry);
		loads -= 64;
	}
	if (loads >= 32) {
		BlockOfLoads4<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 32>(d_in_keys, offset, encoded_carry);
		loads -= 32;
	}
	if (loads >= 16) {
		BlockOfLoads4<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 16>(d_in_keys, offset, encoded_carry);
		loads -= 16;
	}
	if (loads >= 8) {
		BlockOfLoads4<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 8>(d_in_keys, offset, encoded_carry);
		loads -= 8;
	}
	if (loads >= 4) {
		BlockOfLoads4<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 4>(d_in_keys, offset, encoded_carry);
		loads -= 4;
	}
	if (loads >= 2) {
		BlockOfLoads<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 2>(d_in_keys, offset, encoded_carry);
		loads -= 2;
	}
	if (loads) {
		BlockOfLoads<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor, 1>(d_in_keys, offset, encoded_carry);
	}
	
	return retval;
}


//------------------------------------------------------------------------------
// Reduction/counting Kernel Entry Point
//------------------------------------------------------------------------------

template <typename K, typename V, unsigned int RADIX_BITS, unsigned int BIT, typename PreprocessFunctor>
__launch_bounds__ (SRTS_THREADS, SRTS_REDUCE_CTA_OCCUPANCY(__CUDA_ARCH__))
__global__ 
void RakingReduction(
	K *d_in_keys,
	unsigned int *d_spine,
	CtaDecomposition work_decomposition)
{
	const unsigned int RADIX_DIGITS 		= 1 << RADIX_BITS;

	const unsigned int LOG_SCAN_LANES 		= (RADIX_BITS >= 2) ? RADIX_BITS - 2 : 0;	// Always at least one fours group
	const unsigned int SCAN_LANES 			= 1 << LOG_SCAN_LANES;

	const unsigned int LOG_LANES_PER_WARP 	= (SCAN_LANES > SRTS_WARPS) ? LOG_SCAN_LANES - SRTS_LOG_WARPS : 0;	// Always at least one fours group per warp
	const unsigned int LANES_PER_WARP 		= 1 << LOG_LANES_PER_WARP;
	
	
	
	// Each thread gets its own column of fours-groups (for conflict-free updates)
	__shared__ unsigned int encoded_carry[SCAN_LANES][SRTS_THREADS];			

	// Each thread is also responsible for aggregating an unencoded segment of a fours-group
	unsigned int local_counts[LANES_PER_WARP][4];								

	// Calculate our threadblock's range
	unsigned int offset, block_elements;
	if (blockIdx.x < work_decomposition.num_big_blocks) {
		offset = work_decomposition.big_block_elements * blockIdx.x;
		block_elements = work_decomposition.big_block_elements;
	} else {
		offset = (work_decomposition.normal_block_elements * blockIdx.x) + (work_decomposition.num_big_blocks * SRTS_CYCLE_ELEMENTS(__CUDA_ARCH__, K, V));
		block_elements = work_decomposition.normal_block_elements;
	}
	
	// Initialize local counts
	#pragma unroll 
	for (int LANE = 0; LANE < (int) LANES_PER_WARP; LANE++) {
		local_counts[LANE][0] = 0;
		local_counts[LANE][1] = 0;
		local_counts[LANE][2] = 0;
		local_counts[LANE][3] = 0;
	}
	
	// Reset encoded counters
	ResetEncodedCarry<SCAN_LANES>(encoded_carry);
	
	// Process loads
	unsigned int loads = block_elements >> SRTS_LOG_THREADS;
	unsigned int unreduced_loads = ProcessLoads<K, RADIX_DIGITS, SCAN_LANES, LANES_PER_WARP, BIT, PreprocessFunctor>(
		d_in_keys,
		loads,
		offset,
		encoded_carry,
		local_counts);
	
	// Cleanup if we're the last block  
	if ((blockIdx.x == gridDim.x - 1) && (work_decomposition.extra_elements_last_block)) {

		const unsigned int LOADS_PER_CYCLE = SRTS_CYCLE_ELEMENTS(__CUDA_ARCH__, K, V) / SRTS_THREADS;
		
		// If extra guarded loads may cause overflow, reduce now and reset counters
		if (unreduced_loads + LOADS_PER_CYCLE > 255) {
		
			ReduceEncodedCounts<RADIX_DIGITS, SCAN_LANES, LANES_PER_WARP, BIT, false>(
					local_counts, 
					encoded_carry);
			
			ResetEncodedCarry<SCAN_LANES>(encoded_carry);
		}
		
		// perform up to LOADS_PER_CYCLE extra guarded loads
		#pragma unroll
		for (int EXTRA_LOAD = 0; EXTRA_LOAD < (int) LOADS_PER_CYCLE; EXTRA_LOAD++) {
			if (threadIdx.x + (SRTS_THREADS * EXTRA_LOAD) < work_decomposition.extra_elements_last_block) {
				K key = d_in_keys[offset + (SRTS_THREADS * EXTRA_LOAD) + threadIdx.x];
				Bucket<K, RADIX_DIGITS, SCAN_LANES, BIT, PreprocessFunctor>(key, encoded_carry);
			}
		}
	}
	
	// Aggregate 
	ReduceEncodedCounts<RADIX_DIGITS, SCAN_LANES, LANES_PER_WARP, BIT, true>(
		local_counts, 
		encoded_carry);

	// Write carry in parallel (carries per row are in the first four bytes of each row) 
	if (threadIdx.x < RADIX_DIGITS) {

		unsigned int row = threadIdx.x >> 2;		
		unsigned int col = threadIdx.x & 3;			 
		d_spine[(gridDim.x * threadIdx.x) + blockIdx.x] = encoded_carry[row][col];
	}
} 

 


#endif


