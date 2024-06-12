

# 3-In-1 MLB Game Stats Pipeline/Predictor/Chat-Bot




## Overview
This project involves fetching historical & current MLB game stats from the MLB API. Processing and storing the data in IceBerg tables. Training multiple ML models to predict future game stats of the current season, and storing these predictions back into Iceberg tables. All tables are converted to text embeddings using OpenAI's embeddings and stored in a Qdrant vector store. A RAG model is set up to retrieve the embeddings in Qdrant that match closest to the query embeddings generated by SentenceTransformers and combines into text prompts. These prompts are fed into OpenAI's GPT-3.5-turbo, which generates responses to user queries. The responses from OpenAI GPT are then displayed in the Streamlit app. The responses can also be converted to an audio file using gTTS (Google Text-to-Speech) and played back within the Streamlit app.




## Data Retrieval/Storage Process




## ML Process


## RAG Model/Chat UI Process


# MORE UPDATES WILL BE ADDED DAILY. MY GOAL IS TO HAVE README COMPLETED BY WEEKEND. 


![MLB Diagram](/MLB_Diagram_Update.png)

