#include "stdio.h"
#include "stdlib.h"
#include "math.h"
#include "vector_types.h"
#include "assert.h"
#include <vector>

#define CUDA_CHECK_RETURN(value) {				\
  cudaError_t _m_cudaStat = value;				\
  if (_m_cudaStat != cudaSuccess) {				\
    fprintf(stderr, "Error %s at line %d in file %s\n",	\
    cudaGetErrorString(_m_cudaStat), __LINE__, __FILE__);	\
    exit(1);							\
  }								\
}

//----------------------------------------------------
// Structures
//----------------------------------------------------
typedef float4 point_cu;
typedef float4 vector_cu;

typedef struct triangle_cu{
  point_cu A;
  point_cu B;
  point_cu C;
} TRIANGLE_CU;

typedef struct prism_cu{
  triangle_cu t1; // height in w coordinate
} PRISM_CU;

typedef struct plane_cu {
  point_cu P;
  vector_cu normal;
} PLANE_CU;

typedef struct ray_cu {
  point_cu P;
  vector_cu direction;
} RAY_CU;

//----------------------------------------------------
// Device Code
//----------------------------------------------------
__device__ float4 to_barycentric_gpu(triangle_cu t, point_cu p){
  float x1,x2,x3, y1,y2,y3, x,y;
  float4 b;

  x1 = t.A.x;
  x2 = t.B.x;
  x3 = t.C.x;

  y1 = t.A.y;
  y2 = t.B.y;
  y3 = t.C.y;
    
  x = p.x;
  y = p.y;

  b.x = ((y2-y3)*(x-x3)+(x3-x2)*(y-y3)) / ((y2-y3)*(x1-x3)+(x3-x2)*(y1-y3));
  b.y = ((y3-y1)*(x-x3)+(x1-x3)*(y-y3)) / ((y2-y3)*(x1-x3)+(x3-x2)*(y1-y3));
  b.z = 1 - b.x - b.y;
  b.w = 0;
  return b;
}

__device__ point_cu intersection_gpu(plane_cu pl, ray_cu r){
  point_cu intersection_point = {0.0,0.0,0.0};

  float t = 0;
  float d = 0;

  // vector coordinates
  float n1, n2, n3, x1, x2, x3, p1, p2, p3, a1, a2, a3;
  
  // just get the coordinates from the structs
  n1 = pl.normal.x;
  n2 = pl.normal.y;
  n3 = pl.normal.z;

  a1 = pl.P.x;
  a2 = pl.P.y;
  a3 = pl.P.z;

  x1 = r.P.x;
  x2 = r.P.y;
  x3 = r.P.z;

  p1 = r.direction.x;
  p2 = r.direction.y;
  p3 = r.direction.z;

  // calculation of intersection
  d = n1*a1 + n2*a2 + n3*a3;
  t = (d - n1*x1 - n2*x2 - n3*x3) / (n1*p1 + n2*p2 + n3*p3);

  intersection_point.x = x1 + t * p1;
  intersection_point.y = x2 + t * p2;
  intersection_point.z = x3 + t * p3;

  return intersection_point;

}

__device__ bool collide_gpu(triangle_cu t, point_cu p){
  float4 b = to_barycentric_gpu(t, p);
  return  (b.x > 0) && (b.x < 1) && (b.y > 0) && (b.y < 1) && (b.z > 0) && (b.z < 1) && (b.z == b.z);
}

__device__ bool collide_gpu(triangle_cu t, ray_cu r){
  plane_cu pl;
  float b1, b2, b3, c1, c2, c3;

  b1 = t.B.x - t.A.x;
  b2 = t.B.y - t.A.y;
  b3 = t.B.z - t.A.z;

  c1 = t.C.x - t.A.x;
  c2 = t.C.y - t.A.y;
  c3 = t.C.z - t.A.z;

  pl.P = t.A;
  pl.normal.x = (b2*c3 - b3*c2);
  pl.normal.y = (b3*c1 - b1*c3);
  pl.normal.z = (b1*c2 - b2*c1);

  return collide_gpu(t, intersection_gpu(pl, r));
}

__device__ bool collide_gpu(prism_cu pr, ray_cu r){
  bool has_collide = false;
  point_cu A1 = pr.t1.A;
  point_cu B1 = pr.t1.B;
  point_cu C1 = pr.t1.C;
  point_cu A2 = {pr.t1.A.x, pr.t1.A.y, pr.t1.A.w, 1};
  point_cu B2 = {pr.t1.B.x, pr.t1.B.y, pr.t1.B.w, 1};
  point_cu C2 = {pr.t1.C.x, pr.t1.C.y, pr.t1.C.w, 1};

  triangle_cu triangles[8] = {
    pr.t1,
    {A2, B2, C2},
    {A1, B1, A2},
    {B1, B2, A2},
    {B1, C1, C2},
    {B1, B2, C2},
    {A1, C1, C2},
    {A1, A2, C2}};

  has_collide = has_collide || collide_gpu(triangles[0], r);
  has_collide = has_collide || collide_gpu(triangles[1], r);
  has_collide = has_collide || collide_gpu(triangles[2], r); 
  has_collide = has_collide || collide_gpu(triangles[3], r);
  has_collide = has_collide || collide_gpu(triangles[4], r); 
  has_collide = has_collide || collide_gpu(triangles[5], r); 
  has_collide = has_collide || collide_gpu(triangles[6], r); 
  has_collide = has_collide || collide_gpu(triangles[7], r);

  return has_collide;
}

__global__ void trace_on_prisms(prism_cu* prisms, const unsigned max_prisms, ray_cu* rays, const unsigned max_rays, float4 *collisions){
  // Cuda ids
  //unsigned tid = threadIdx.x;
  //unsigned bid = blockIdx.x + blockIdx.y * gridDim.x;
  
  unsigned gid = blockIdx.x * blockDim.x + threadIdx.x;

  // Local data
  prism_cu prism = prisms[gid];
  unsigned local_collisions = 0;
  unsigned ray_i;

  __syncthreads();
  // Calculation
  for(ray_i = 0; ray_i < max_rays; ++ray_i){
     local_collisions += (1 * (int)collide_gpu(prism, rays[ray_i]));
  
	       
  }
  __syncthreads();
  collisions[gid].x = local_collisions;
  
}

//----------------------------------------------------
// Auxillary function declaration
//----------------------------------------------------
// Geometrie functions
point_cu  collide_triangle(triangle_cu t, ray_cu r);
float  collide_prism(prism_cu pr, ray_cu r);
float4 to_barycentric(triangle_cu t, ray_cu r);
point_cu intersection(plane_cu p, ray_cu r);
float distance(point_cu a, point_cu b);
vector_cu crossproduct(vector_cu a, vector_cu b);
float skalar_mul(vector_cu a, vector_cu b);

// Testdata generation
std::vector<triangle_cu> generate_triangles(int height, int width, float level);
std::vector<prism_cu> generate_prisms(int height, int width, float level);
std::vector<ray_cu> generate_rays(int height, int width, int level, unsigned max_rays);
std::vector<point_cu> generate_samples(int height, int width, int level);
std::vector<ray_cu> generate_sample_rays(int height, int width, int level, unsigned max_rays, point_cu sample);
ray_cu   generate_ray(int height, int weight, int level);

// Debug functions
void print_point(point_cu p);
void print_vector(vector_cu v);
void print_plane(plane_cu pl);

//----------------------------------------------------
// Host Code
//----------------------------------------------------
int main(){
  const unsigned max_rays = 10;
  const unsigned max_triangles = 10;
  const unsigned length = ceil(sqrt(max_triangles / 2));
  const unsigned depth  = 3;
  const unsigned max_prisms = length * length * depth * 2;
  unsigned ray_i, prism_i, sample_i;
  float runtime_gpu = 0.0;
  float runtime_cpu = 0.0;
  cudaEvent_t start, stop;
  bool use_cpu = true;
  bool use_gpu = false;

  // Generate testdata
  std::vector<prism_cu> prisms = generate_prisms(length, length, depth);
  std::vector<point_cu> samples = generate_samples(length, length, depth);
  //std::vector<ray_cu> rays = generate_sample_rays(length, length, depth, max_rays, samples[0]);
  std::vector<ray_cu> rays = generate_rays(length, length, depth, max_rays);
  std::vector<float> collisions(max_prisms, 0);
  std::vector<float> sample_data(samples.size(), 0);
  cudaEventCreate(&start);
  cudaEventCreate(&stop);

  /*
    triangle_cu tr = {
    {1, 1, 1, 1},
    {3, 1, 1, 1},
    {1, 3, 1, 1}};

    triangle_cu tr2 = {
    {1, 1, 1, 1},
    {1, 1, 4, 1},
    {1, 3, 1, 1}};

    prism_cu pr = {tr};

    ray_cu r = {
    {0, 0.5, 0.5, 1},
    {1, 0, 0, 0}};
  */

  // CPU Raytracing

  cudaEventRecord(start, 0);
  if(use_cpu){
    /*

      for(ray_i = 0; ray_i < rays.size(); ++ray_i){
      for(prism_i = 0; prism_i < prisms.size(); ++prism_i){
      float distance = collide(prisms[prism_i], rays[ray_i]);
      //float distance = collide(prisms[prism_i], r);
      if(distance > 0){
      fprintf(stdout, "CPU: Ray %d hits on prism %d with distance %f\n", ray_i, prism_i, distance);
      collisions[prism_i]++;
      }

      }
      }
    */
    

    for(sample_i = 0; sample_i < samples.size(); ++sample_i){
      std::vector<ray_cu> rays = generate_sample_rays(length, length, depth, max_rays, samples[sample_i]);
      for(ray_i = 0; ray_i < rays.size(); ++ray_i){
	for(prism_i = 0; prism_i < prisms.size(); ++prism_i){
	  float distance = collide_prism(prisms[prism_i], rays[ray_i]);
	  //print_point(rays[ray_i].P);
	  //print_point(rays[ray_i].direction);
	  if(distance > 0){
	    fprintf(stdout, "CPU:Sample %d Ray %d hits on prism %d with distance %f\n", sample_i, ray_i, prism_i, distance);
	    sample_data[sample_i] += distance * 1;
	  }

	}

      }

    }

    for(sample_i = 0; sample_i < samples.size(); ++sample_i){
      fprintf(stdout, "CPU: Sample %d with value %f \n", sample_i, sample_data[sample_i]);
    }

    /*
      point_cu p = collide(tr2, r);
      print_point(p);

      float distance = collide(pr, r);
      if(distance > 0){ 
      fprintf(stderr, "CPU: Ray hit with distance %f\n", distance); 
      } 
    */

    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&runtime_cpu, start, stop);
  }

  // GPU Raytracing
  ray_cu* h_rays, *d_rays;
  prism_cu* h_prisms, *d_prisms;
  float4* h_collisions, *d_collisions;
  int threads = 256;
  int blocks = ceil(max_prisms / threads);
  if(use_gpu){

    // Memory allocation on host
    CUDA_CHECK_RETURN(cudaHostAlloc( (void**)&h_prisms, max_prisms * sizeof(prism_cu), cudaHostAllocDefault));
    CUDA_CHECK_RETURN(cudaHostAlloc( (void**)&h_rays, max_rays * sizeof(ray_cu), cudaHostAllocDefault));
    CUDA_CHECK_RETURN(cudaHostAlloc( (void**)&h_collisions, max_prisms * sizeof(float4), cudaHostAllocDefault));

    // Memory initialisation on host
    for(ray_i = 0; ray_i < max_rays; ++ray_i){
      h_rays[ray_i] = rays[ray_i];
    }
    for(prism_i = 0; prism_i < max_prisms; ++prism_i){
      h_collisions[prism_i].x = 0;
      h_prisms[prism_i] = prisms[prism_i];
    }

    // Memory allocation on device
    CUDA_CHECK_RETURN(cudaMalloc(&d_rays, max_rays * sizeof(ray_cu)));
    CUDA_CHECK_RETURN(cudaMalloc(&d_prisms, max_prisms * sizeof(prism_cu)));
    CUDA_CHECK_RETURN(cudaMalloc(&d_collisions, max_prisms * sizeof(float4)));

    // Copy data from host to device
    cudaEventRecord(start, 0);
    CUDA_CHECK_RETURN(cudaMemcpy(d_rays, h_rays, max_rays * sizeof(ray_cu), cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(d_prisms, h_prisms, max_prisms * sizeof(prism_cu), cudaMemcpyHostToDevice));
    CUDA_CHECK_RETURN(cudaMemcpy(d_collisions, h_collisions, max_prisms * sizeof(float4), cudaMemcpyHostToDevice));

    // Start kernel
    trace_on_prisms<<<threads, blocks>>>(d_prisms, max_prisms, d_rays, max_rays, d_collisions);

    // Copy data from device to host
    CUDA_CHECK_RETURN(cudaMemcpy(h_collisions, d_collisions, max_prisms * sizeof(float4), cudaMemcpyDeviceToHost));

    // Evaluate device data
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);
    cudaEventElapsedTime(&runtime_gpu, start, stop);
    for(prism_i = 0; prism_i < max_prisms; ++prism_i){
      if(h_collisions[prism_i].x > 0)
	fprintf(stderr, "GPU: (%f, %f, %f, %f) collission on prism %d\n", h_collisions[prism_i].x, h_collisions[prism_i].y, h_collisions[prism_i].z, h_collisions[prism_i].w, prism_i);

    }
    for(prism_i = 0; prism_i < max_prisms; ++prism_i){
      if((h_collisions[prism_i].x != collisions[prism_i]) && use_cpu && use_gpu){
	fprintf(stderr, "\033[31;1m[Error]\033[m CPU(%.0f) != GPU(%.0f) on prism %d\n",collisions[prism_i], h_collisions[prism_i].x, prism_i);
      }
    }
  }

  fprintf(stderr, "\n");
  fprintf(stderr, "Prism       : %d\n", max_prisms);
  fprintf(stderr, "Triangles   : %d\n", max_prisms * 8);
  fprintf(stderr, "Rays        : %d\n", max_rays);
  fprintf(stderr, "GPU Blocks  : %d\n", blocks);
  fprintf(stderr, "GPU Threads : %d\n", threads);
  fprintf(stderr, "Runtime_GPU : %f s\n", runtime_gpu / 1000.0);
  fprintf(stderr, "Runtime_CPU : %f s\n", runtime_cpu / 1000.0);
  fprintf(stderr, "\n");

  // Cleanup
  cudaFreeHost(h_rays);
  cudaFreeHost(h_prisms);
  cudaFreeHost(h_collisions);

  return 0;
}

//----------------------------------------------------
// Auxillary function definition
//----------------------------------------------------

/**
   @brief Algorithm based on a paper. exact copy of pseudo code.
 **/
float4 to_barycentric(triangle_cu tr, ray_cu ray){
  float4 b = {0,0,0,0};
  vector_cu e1, e2, q, s, r;
  point_cu p0, p1, p2;
  float a, f, u, v, t;

  p0 = tr.A;
  p1 = tr.B;
  p2 = tr.C;

  e1.x = p1.x - p0.x;
  e1.y = p1.y - p0.y;
  e1.z = p1.z - p0.z;

  e2.x = p2.x - p0.x;
  e2.y = p2.y - p0.y;
  e2.z = p2.z - p0.z;

  q = crossproduct(ray.direction, e2);
  a = skalar_mul(e1, q);
  
  // a is to close to 0
  if(fabs(a) < 0.000001)
    return b;

  f = 1 / a;
  
  s.x = ray.P.x - p0.x;
  s.y = ray.P.y - p0.y;
  s.z = ray.P.z - p0.z;

  u = f * skalar_mul(s, q);

  if(u < 0.0)
    return b;

  r = crossproduct(s, e1);
  v = f * skalar_mul(ray.direction, r);
  if( v < 0.0 || (u + v) > 1)
    return b;
  
  t = f * skalar_mul(e2, q);
  
  b.x = u;
  b.y = v;
  b.z = t;
  b.w = 1;

  return b;
}

/**
   @brief Detects collisions of a triangle and a ray without
   a precondition.
**/
point_cu collide_triangle(triangle_cu t, ray_cu r){
  plane_cu pl;
  float b1, b2, b3, c1, c2, c3;

  b1 = t.B.x - t.A.x;
  b2 = t.B.y - t.A.y;
  b3 = t.B.z - t.A.z;

  c1 = t.C.x - t.A.x;
  c2 = t.C.y - t.A.y;
  c3 = t.C.z - t.A.z;

  pl.P = t.A;
  pl.normal.x = (b2*c3 - b3*c2);
  pl.normal.y = (b3*c1 - b1*c3);
  pl.normal.z = (b1*c2 - b2*c1);

  float4 b = to_barycentric(t, r);
  // Maybe we can calculate intersection be barycentric coords
  point_cu p = intersection(pl, r);
  if(b.w == 1){
    return p;
  }
  else{
    point_cu no_inter = {0,0,0,0}; 
    return no_inter;
  }

}

float collide_prism(prism_cu pr, ray_cu r){
  //bool has_collide;
  point_cu intersections[2];
  point_cu A1 = pr.t1.A;
  point_cu B1 = pr.t1.B;
  point_cu C1 = pr.t1.C;
  point_cu A2 = {pr.t1.A.x, pr.t1.A.y, pr.t1.A.z + pr.t1.A.w, 1};
  point_cu B2 = {pr.t1.B.x, pr.t1.B.y, pr.t1.B.z + pr.t1.B.w, 1};
  point_cu C2 = {pr.t1.C.x, pr.t1.C.y, pr.t1.C.z + pr.t1.C.w, 1};

  triangle_cu triangles[8] = {
    pr.t1,
    {A2, B2, C2},
    {A1, B1, A2},
    {B1, B2, A2},
    {B1, C1, C2},
    {B1, B2, C2},
    {A1, C1, C2},
    {A1, A2, C2}};

  unsigned i; 
  unsigned j = 0;
  // test for collision on all triangles of an prism
  for(i = 0; i < 8; ++i){
    point_cu p = collide_triangle(triangles[i], r);
    if(p.x == 0 && p.y == 0 && p.z == 0 && p.w == 0)
    // No Collision for this triangle
      continue;
    // Filter double Collision on edges or vertices
    if(j != 0){
      if(intersections[j-1].x != p.x || intersections[j-1].y != p.y || intersections[j-1].z != p.z){
	intersections[j++] = p;
      }
    }
    else{
      intersections[j++] = p;
    }

  }
  if(j > 1)
    return distance(intersections[0], intersections[1]);
  else
    return 0;
}

/**
   @brief Intersection calculates the intersection between a plane p
   and a ray r. There is no detection for rays in the plane
   or for parallel plane. 

   It uses the normal of the plane to derive the coordinate form 
   of the plane. With the help of a coordinate form it is very
   easy to get the intersection point between a ray and a plane.

   ray   g: y~ = x~ + t*p~
   plane E: y~ = a~ + r*b~ + s*c~
   d  = n1*(x1+t*p1) + n2*(x2+t*p2) + n3*(x3+t*p3)
   d  = n~ * a~
**/
point_cu intersection(plane_cu pl, ray_cu r){
  point_cu intersection_point = {0.0,0.0,0.0, 1};

  float t, d;

  // vector coordinates
  float n1, n2, n3, x1, x2, x3, p1, p2, p3, a1, a2, a3;
  
  // just get the coordinates from the structs
  n1 = pl.normal.x;
  n2 = pl.normal.y;
  n3 = pl.normal.z;

  a1 = pl.P.x;
  a2 = pl.P.y;
  a3 = pl.P.z;

  x1 = r.P.x;
  x2 = r.P.y;
  x3 = r.P.z;

  p1 = r.direction.x;
  p2 = r.direction.y;
  p3 = r.direction.z;

  // calculation of intersection
  // this case for parallel rays, will be ignored for easier calculations
  float tmp = (n1*p1 + n2*p2 + n3*p3);
  if(tmp == 0)
    return intersection_point;

  d = n1*a1 + n2*a2 + n3*a3;
  t = (d - n1*x1 - n2*x2 - n3*x3) / tmp;

  intersection_point.x = x1 + t * p1;
  intersection_point.y = x2 + t * p2;
  intersection_point.z = x3 + t * p3;
  intersection_point.w = 1;
  return intersection_point;

}

float distance(point_cu a, point_cu b){
  float d = sqrt(pow((b.x - a.x), 2) + pow((b.y - a.y),2) + pow((b.z - a.z),2));
  return fabs(d);
}

std::vector<triangle_cu> generate_triangles(int height, int weight, float level){
  int h,w;
  std::vector<triangle_cu> triangles;
  for(h = 0; h < height; ++h){
    for(w = 0; w < weight; ++w){
      triangle_cu t1 = {
	{float(h), float(w), level, 1},
	{float(h), float(w+1), level, 1},
	{float(h+1), float(w), level, 1}};
      triangle_cu t2 = {
	{float(h), float(w+1), level, 1},
	{float(h+1), float(w+1), level, 1},
	{float(h+1), float(w), level, 1}};
      triangles.push_back(t1);
      triangles.push_back(t2);

    }

  }

  return triangles;
}

std::vector<prism_cu> generate_prisms(int height, int width, float level){
  int h,w,l;
  std::vector<prism_cu> prisms;
  for(l = 0; l < level; ++l){
    for(h = 0; h < height; ++h){
      for(w = 0; w < width; ++w){
	triangle_cu a1 = {
	  {float(h), float(w), l, l+1},
	  {float(h), float(w+1), l, l+1},
	  {float(h+1), float(w), l, l+1}};
	triangle_cu b1 = {
	  {float(h), float(w+1), l, 1+1},
	  {float(h+1), float(w+1), l, 1+1},
	  {float(h+1), float(w), l, 1+1}};
      
	prism_cu pr1 = {a1};
	prism_cu pr2 = {b1};

	prisms.push_back(pr1);
	prisms.push_back(pr2);

      }

    }

  }

  return prisms;
}

ray_cu generate_ray(const int heigth, const int width, const int level){
  float rand_heigth = float(rand() % heigth) + (rand() / (float) RAND_MAX);
  float rand_width  = float(rand() % width ) + (rand() / (float) RAND_MAX);
  float rand_level  = float(rand() % level ) + (rand() / (float) RAND_MAX);

  float dir_x = (rand() / (float) RAND_MAX);
  float dir_y = (rand() / (float) RAND_MAX);
  float dir_z = (rand() / (float) RAND_MAX);

  ray_cu r = {
    {rand_heigth, rand_width, rand_level, 1},
    {dir_x, dir_y, dir_z, 0}};
  return r;
}

std::vector<ray_cu> generate_rays(const int height, const int width, const int level, const unsigned max_rays){
  std::vector<ray_cu> rays;
  unsigned ray_i;
  for(ray_i = 0; ray_i < max_rays; ++ray_i){
    ray_cu ray = generate_ray(height, width, level);
    rays.push_back(ray);
  }
  return rays;
}

std::vector<point_cu> generate_samples(int height, int width, int level){
  std::vector<point_cu> sample_points;
  int h,w,l;
  for(l = 0; l < level; ++l){
    for(h = 0; h < height; ++h){
      for(w = 0; w < width; ++w){
	point_cu p = {float(h), float(w), float(l), 0};
	sample_points.push_back(p);
      }
    }
  }
  return sample_points;
}

std::vector<ray_cu> generate_sample_rays(int height, int width, int level, unsigned max_rays, point_cu sample){
  std::vector<ray_cu> rays;
  unsigned ray_i;
  for(ray_i = 0; ray_i < max_rays; ++ray_i){
    ray_cu ray = generate_ray(height, width, level);
    ray.direction.x  =  sample.x - ray.P.x;
    ray.direction.y  =  sample.y - ray.P.y;
    ray.direction.z  =  sample.z - ray.P.z;
    rays.push_back(ray);
  }
  return rays;
}

vector_cu crossproduct(vector_cu a, vector_cu b){
  vector_cu c = {
    a.y*b.z - a.z*b.y,
    a.z*b.x - a.x*b.z,
    a.x*b.y - a.y*b.x
  };
  return c;
}

float skalar_mul(vector_cu a, vector_cu b){
  return a.x*b.x + a.y*b.y + a.z*b.z;
}

void print_point(point_cu p){
  fprintf(stderr, "Point (%f, %f, %f)\n",p.x, p.y, p.z);

}

void print_vector(vector_cu v){
  fprintf(stderr, "Vector (%f, %f, %f)\n",v.x, v.y, v.z);

}

void print_plane(plane_cu pl){
  fprintf(stderr, "Plane: \n\t");
  print_point(pl.P);
  fprintf(stderr, "\t");
  print_vector(pl.normal);
}
