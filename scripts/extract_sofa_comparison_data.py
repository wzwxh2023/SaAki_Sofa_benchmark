
import pandas as pd
from sqlalchemy import create_engine
import os
import sys

# --- Database Connection Details ---
# It's recommended to use environment variables for security,
# but we are using the provided details directly as requested.
DB_HOST = "172.19.160.1"
DB_NAME = "mimiciv"
DB_USER = "postgres"
DB_PASS = "188211"

# Construct the database URI
DATABASE_URI = f"postgresql+psycopg2://{DB_USER}:{DB_PASS}@{DB_HOST}/{DB_NAME}"

# --- Output File Configuration ---
OUTPUT_DIR = "analysis_data"
OUTPUT_FILENAME = "sofa_comparison_main_dataset.csv"
OUTPUT_FILEPATH = os.path.join(OUTPUT_DIR, OUTPUT_FILENAME)

# --- SQL Query ---
# Converted to a single line to avoid multi-line string parsing issues.
QUERY = "WITH first_stay_ids AS (SELECT subject_id, stay_id, hadm_id, ROW_NUMBER() OVER (PARTITION BY subject_id ORDER BY intime ASC) as rn FROM mimiciv_icu.icustays), first_admission_stays AS (SELECT stay_id, hadm_id, subject_id FROM first_stay_ids WHERE rn = 1), sofa1 AS (SELECT fas.subject_id, s1.sofa AS sofa1_score, s1.respiration AS sofa1_respiration, s1.coagulation AS sofa1_coagulation, s1.liver AS sofa1_liver, s1.cardiovascular AS sofa1_cardiovascular, s1.cns AS sofa1_cns, s1.renal AS sofa1_renal FROM mimiciv_derived.first_day_sofa s1 INNER JOIN first_admission_stays fas ON s1.stay_id = fas.stay_id), sofa2 AS (SELECT fas.subject_id, s2.sofa2 AS sofa2_score, s2.respiration AS sofa2_respiration, s2.coagulation AS sofa2_coagulation, s2.liver AS sofa2_liver, s2.cardiovascular AS sofa2_cardiovascular, s2.cns AS sofa2_cns, s2.renal AS sofa2_renal FROM mimiciv_derived.first_day_sofa2 s2 INNER JOIN first_admission_stays fas ON s2.stay_id = fas.stay_id) SELECT fas.subject_id, fas.stay_id, fas.hadm_id, adm.hospital_expire_flag, s1.sofa1_score, s2.sofa2_score, s1.sofa1_respiration, s2.sofa2_respiration, s1.sofa1_coagulation, s2.sofa2_coagulation, s1.sofa1_liver, s2.sofa2_liver, s1.sofa1_cardiovascular, s2.sofa2_cardiovascular, s1.sofa1_cns, s2.sofa2_cns, s1.sofa1_renal, s2.sofa2_renal FROM first_admission_stays fas LEFT JOIN sofa1 s1 ON fas.subject_id = s1.subject_id LEFT JOIN sofa2 s2 ON fas.subject_id = s2.subject_id LEFT JOIN mimiciv_core.admissions adm ON fas.hadm_id = adm.hadm_id ORDER BY fas.subject_id;"

def main():
    print("Connecting to the database...")
    try:
        engine = create_engine(DATABASE_URI)
        with engine.connect() as connection:
            print("Connection successful. Executing query...")
            df = pd.read_sql(QUERY, connection)
            print(f"Query executed successfully. Found {len(df)} records.")

            # Ensure the output directory exists
            os.makedirs(OUTPUT_DIR, exist_ok=True)

            print(f"Saving data to {OUTPUT_FILEPATH}...")
            df.to_csv(OUTPUT_FILEPATH, index=False)
            print("Data saved successfully.")
            
            # Display basic info about the extracted data
            print("\n--- Data Preview ---")
            print(df.head())
            print("\n--- Data Info ---")
            df.info()

    except Exception as e:
        print(f"An error occurred: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
