# Project3

# Group Members
Patriel Stapleton and Helen Radomski

# What is working
Every feature described in Ch 4 of the paper has been acheived. 
- Creating a new chord network with one node
- Joining new nodes to the chord network via an existing node
  - This also includes the functions for finding a successor, closest preceding node and closest following node
- Condensed finger table: Track only the max key a node serves rather than all
 - To support this we included the functions to keep the finger table up to date:
  - Periodcly stablize the finger table by checking for valid predecessor to sucessor relationship
  - Periodicly fix the finger table to account for any new nodes or updated predecessor and sucessor relations

# Largest Networks

No. of Queries    1       10      25      75      97  
No. of Nodes      7000    5000    2500    2500    1900
Average No. Hops  4.5674  5.4267  5.7795  4.1477  5.8221

We observed that in smaller networks sizes such as 10 and 50, the number of queries did not significantly affect 
the number of hops. For example for a network of 10 it took an average of 2.2 hops to deliver a message when each 
node had 1 query. But when each node had 97 queries it still took an average of 2.2 hops.

There was a slight increase in average hops for larger networks. For a netowrk of 1000 where each node had a single
query it took an average of 4.586 hops where for 97 queries it took on average 5.798. This aligned with the logarithmic
completion time the paper outlined. Even though the number of nodes significantly increased the increase in average
number of hops was slight. Additionally, we generated graphs to confirm this.
                        

