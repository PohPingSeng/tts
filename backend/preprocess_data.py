import pandas as pd
import numpy as np
import joblib
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import LabelEncoder, StandardScaler

# Load the dataset
file_path = r"C:\Users\User\tts\dataset\data.csv"
df = pd.read_csv(file_path, header=0)

# Drop completely empty rows and columns
df = df.dropna(how="all")
df = df.dropna(axis=1, how="all")

# Fill missing values except for Place ID (we want to keep Place ID as is)
for column in df.columns:
    if column != 'Place ID':  # Don't fill Place ID
        if df[column].dtype == "object":
            df[column] = df[column].fillna(df[column].mode()[0])

# Create location groups based on personality and preferences
df['location_group'] = df.apply(
    lambda x: f"{x['Personality Traits']}_{x['Tourism Category']}_{x['Travelling Concerns']}", 
    axis=1
)

# Initialize label encoders for each categorical feature
label_encoders = {}
categorical_features = [
    'Personality Traits',
    'Tourism Category',
    'Travel Motivation',
    'Travelling Concerns'
]

# Create binary features
binary_features = []
for feature in categorical_features:
    if feature in df.columns:
        unique_values = df[feature].unique()
        for value in unique_values:
            if pd.notna(value):
                col_name = f"{feature}_{value}".lower().replace(" ", "_").replace(",", "").replace("&", "and")
                df[col_name] = (df[feature] == value).astype(int)
                binary_features.append(col_name)

# Encode location groups
le_location = LabelEncoder()
df['location_group_encoded'] = le_location.fit_transform(df['location_group'])

# Create the final feature matrix using only binary features
X = df[binary_features].copy()
y = df['location_group_encoded']

# Split the data
X_train, X_test, y_train, y_test = train_test_split(
    X, y,
    test_size=0.2,
    random_state=42,
    stratify=y
)

# Modify the location groups creation to properly include place IDs
location_groups = {}
for group_name, group_df in df.groupby('location_group'):
    locations = []
    for _, row in group_df.iterrows():
        location_data = {
            "name": row['Location'],
            "place_id": row['Place ID']  # Changed from row.get('place_id', None)
        }
        locations.append(location_data)
    location_groups[group_name] = locations

# Save the processed data and metadata
joblib.dump((X_train, X_test, y_train, y_test), "processed_data.pkl")
joblib.dump({
    'location_encoder': le_location,
    'feature_columns': binary_features,
    'location_groups': location_groups
}, "model_metadata.pkl")

print("\n=== Dataset Information ===")
print(f"Number of features: {X.shape[1]}")
print(f"Number of samples: {X.shape[0]}")
print(f"Number of unique location groups: {len(df['location_group'].unique())}")
print(f"Training samples: {X_train.shape[0]}")
print(f"Testing samples: {X_test.shape[0]}")

# Print some example groups to verify
print("\n=== Example Location Groups with Place IDs ===")
for group_name, locations in list(location_groups.items())[:3]:
    print(f"\nGroup: {group_name}")
    print("Locations:")
    for loc in locations[:3]:  # Show first 3 locations per group
        print(f"- Name: {loc['name']}")
        print(f"  Place ID: {loc['place_id']}")

# Print feature names
print("\n=== Features Used ===")
print(binary_features)

# Print group distribution
print("\n=== Group Distribution ===")
group_counts = df['location_group'].value_counts()
print(f"Average locations per group: {group_counts.mean():.2f}")
print(f"Min locations per group: {group_counts.min()}")
print(f"Max locations per group: {group_counts.max()}")
